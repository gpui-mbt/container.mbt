// Copyright 2026 gpui-mbt contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Feed `raw` one byte at a time (worst-case split), then EOF.
fn decode_split_1(raw : Bytes) -> HttpResponse raise {
  let dec = HttpResponseDecoder::new()
  for i = 0; i < raw.length(); i = i + 1 {
    dec.feed(raw[i:i + 1].to_owned())
  }
  dec.eof()
  dec.response()
}

///|
/// Feed `raw` in a single chunk, then EOF.
fn decode_whole(raw : Bytes) -> HttpResponse raise {
  let dec = HttpResponseDecoder::new()
  dec.feed(raw)
  dec.eof()
  dec.response()
}

///|
fn text(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
test "Content-Length body decodes byte-by-byte" {
  let resp = decode_split_1(
    text("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"),
  )
  assert_eq(resp.status, 200)
  assert_eq(resp.reason, "OK")
  assert_eq(resp.body, b"hello")
}

///|
test "chunked response decodes at every boundary" {
  let raw = text(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n6\r\npedia \r\nC;foo=bar\r\nin\r\n\r\nchunks\r\n0\r\nX-Trailer: ok\r\n\r\n",
  )
  let resp = decode_split_1(raw)
  assert_eq(resp.status, 200)
  assert_eq(resp.body, text("Wikipedia in\r\n\r\nchunks"))
  // and whole-buffer feeding gives the same result
  let resp2 = decode_whole(raw)
  assert_eq(resp2.body, resp.body)
}

///|
test "truncated Content-Length body at EOF is an error" {
  let dec = HttpResponseDecoder::new()
  dec.feed(text("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe"))
  try dec.eof() catch {
    Truncated(_) => return
    err => fail("expected Truncated, got \{err}")
  } noraise {
    _ => fail("expected Truncated")
  }
}

///|
test "close-delimited response completes at EOF" {
  let resp = decode_split_1(
    text("HTTP/1.1 200 OK\r\nDate: today\r\n\r\nstreamed"),
  )
  assert_eq(resp.status, 200)
  assert_eq(resp.body, text("streamed"))
}

///|
test "body limit boundary: exactly 64MiB succeeds, +1 fails" {
  let dec = HttpResponseDecoder::new()
  dec.feed(text("HTTP/1.1 200 OK\r\nContent-Length: 67108864\r\n\r\n"))
  dec.feed(Bytes::make(64 * 1024 * 1024, 0))
  assert_true(dec.is_complete())
  assert_eq(dec.response().body.length(), 64 * 1024 * 1024)
  // +1 byte over the limit (via a small custom limit to keep it fast too):
  // the Content-Length check rejects it at feed time.
  let dec2 = HttpResponseDecoder::new(max_body=8)
  try
    dec2.feed(text("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n123456789"))
  catch {
    BodyTooLarge(8) => ()
    err => fail("expected BodyTooLarge(8), got \{err}")
  } noraise {
    _ => fail("expected BodyTooLarge(8)")
  }
}

///|
test "over-limit chunked body fails mid-stream" {
  let dec = HttpResponseDecoder::new(max_body=8)
  dec.feed(text("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"))
  dec.feed(text("8\r\n12345678\r\n"))
  try dec.feed(text("1\r\nx\r\n0\r\n\r\n")) catch {
    BodyTooLarge(8) => return
    err => fail("expected BodyTooLarge, got \{err}")
  } noraise {
    _ => fail("expected BodyTooLarge")
  }
}

///|
test "invalid chunk size and conflicting lengths are rejected" {
  let dec = HttpResponseDecoder::new()
  try
    dec.feed(
      text("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"),
    )
  catch {
    InvalidChunkSize(_) => ()
    err => fail("expected InvalidChunkSize, got \{err}")
  } noraise {
    _ => fail("expected InvalidChunkSize")
  }
  let dec2 = HttpResponseDecoder::new()
  try
    dec2.feed(
      text("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n"),
    )
  catch {
    InconsistentContentLength => ()
    err => fail("expected InconsistentContentLength, got \{err}")
  } noraise {
    _ => fail("expected InconsistentContentLength")
  }
}

///|
test "1xx responses are skipped for the final response" {
  let resp = decode_split_1(
    text(
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
    ),
  )
  assert_eq(resp.status, 200)
  assert_eq(resp.body, b"OK")
}

///|
test "204 and headless responses complete with no body" {
  let resp = decode_whole(text("HTTP/1.1 204 No Content\r\n\r\n"))
  assert_eq(resp.status, 204)
  assert_eq(resp.body.length(), 0)
}

///|
test "malformed status lines and headers are rejected" {
  let cases : Array[String] = [
    "nonsense\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 200 OK\r\nno colon here\r\n\r\n",
    "HTTP/1.1 200 OK\r\n folded\r\n\r\n",
  ]
  for c in cases {
    let dec = HttpResponseDecoder::new()
    try dec.feed(text(c)) catch {
      HttpDecodeError::MalformedStatusLine(_)
      | HttpDecodeError::MalformedHeader(_) => continue
      err => fail("case \{c}: expected malformed-* error, got \{err}")
    } noraise {
      _ => fail("case \{c}: expected a parse error")
    }
  }
}

///|
test "empty and partial responses at EOF are truncated" {
  let dec = HttpResponseDecoder::new()
  try dec.eof() catch {
    Truncated(_) => ()
    err => fail("expected Truncated, got \{err}")
  } noraise {
    _ => fail("expected Truncated")
  }
  let dec2 = HttpResponseDecoder::new()
  dec2.feed(text("HTTP/1.1 200 OK\r\nContent-Leng"))
  try dec2.eof() catch {
    Truncated(_) => ()
    err => fail("expected Truncated, got \{err}")
  } noraise {
    _ => fail("expected Truncated")
  }
}

///|
test "feeding past a complete response is rejected" {
  let dec = HttpResponseDecoder::new()
  dec.feed(text("HTTP/1.1 204 No Content\r\n\r\n"))
  try dec.feed(b"x") catch {
    TrailingData => ()
    err => fail("expected TrailingData, got \{err}")
  } noraise {
    _ => fail("expected TrailingData")
  }
}

///|
test "header casing is insignificant" {
  let resp = decode_whole(
    text("HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\nabc"),
  )
  assert_eq(resp.body, b"abc")
}

///|
test "chunked EOF mid-chunk is truncated" {
  let dec = HttpResponseDecoder::new()
  dec.feed(text("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab"))
  try dec.eof() catch {
    Truncated(_) => ()
    err => fail("expected Truncated, got \{err}")
  } noraise {
    _ => fail("expected Truncated")
  }
}
