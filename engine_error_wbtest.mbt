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
fn msg(body : String) -> Bytes {
  @utf8.encode(body)
}

///|
test "404 on lifecycle ops classifies as container not found" {
  let err = classify_engine_error(
    op="inspect",
    context=ContainerLifecycle,
    status=404,
    body=msg("{\"message\":\"No such container: abc\"}"),
    target="abc",
  )
  guard err is ContainerNotFound(op="inspect", container="abc") else {
    fail("expected ContainerNotFound, got \{err}")
  }
  // stop/rm share the same context so callers can convert to idempotent ok
  let stop_err = classify_engine_error(
    op="stop",
    context=ContainerLifecycle,
    status=404,
    body=msg("{\"message\":\"No such container: xyz\"}"),
    target="xyz",
  )
  guard stop_err is ContainerNotFound(op="stop", container="xyz") else {
    fail("expected ContainerNotFound, got \{stop_err}")
  }
}

///|
test "404 on image resolve classifies as image not found" {
  let err = classify_engine_error(
    op="pull",
    context=ResolveImage,
    status=404,
    body=msg("{\"message\":\"pull access denied for nope\"}"),
    target="registry.example.com/nope:latest",
  )
  guard err
    is ImageNotFound(op="pull", image="registry.example.com/nope:latest") else {
    fail("expected ImageNotFound, got \{err}")
  }
}

///|
test "archive 404 splits path-not-found on the upstream prefix" {
  let err = classify_engine_error(
    op="copy_from",
    context=Archive,
    status=404,
    body=msg(
      "{\"message\":\"Could not find the file /no/such in container abc\"}",
    ),
    target="abc",
    path="/no/such",
  )
  guard err
    is ContainerPathNotFound(op="copy_from", container="abc", path="/no/such") else {
    fail("expected ContainerPathNotFound, got \{err}")
  }
}

///|
test "archive 404 without the prefix stays container not found" {
  for
    body in [
      "{\"message\":\"No such container: abc\"}", "{\"message\":\"different wording\"}",
      "{}", "not json", "",
    ] {
    let err = classify_engine_error(
      op="copy_from",
      context=Archive,
      status=404,
      body=msg(body),
      target="abc",
      path="/x",
    )
    guard err is ContainerNotFound(op="copy_from", container="abc") else {
      fail("body \{body}: expected ContainerNotFound, got \{err}")
    }
  }
}

///|
test "401/403/409/5xx classify with op names and no credentials" {
  let cases : Array[(Int32, String)] = [
    (400, "bad request"),
    (401, "unauthorized"),
    (403, "forbidden"),
    (409, "conflict"),
    (500, "daemon error (500)"),
    (503, "daemon error (503)"),
  ]
  for c in cases {
    let (status, prefix) = c
    let err = classify_engine_error(
      op="stop",
      context=ContainerLifecycle,
      status~,
      body=msg("{\"message\":\"boom\"}"),
      target="ctr",
    )
    assert_true(err.describe().contains(prefix))
    assert_true(err.describe().contains("boom"))
  }
  // no credentials anywhere in any variant
  let err = classify_engine_error(
    op="pull",
    context=ResolveImage,
    status=401,
    body=msg("{\"message\":\"unauthorized: authentication required\"}"),
    target="img",
  )
  guard err is Unauthorized(op="pull", message=_) else {
    fail("expected Unauthorized, got \{err}")
  }
  assert_true(!err.describe().contains("X-Registry-Auth"))
}

///|
test "classification is deterministic" {
  for i = 0; i < 3; i = i + 1 {
    let err = classify_engine_error(
      op="inspect",
      context=ContainerLifecycle,
      status=404,
      body=msg("{\"message\":\"No such container: abc\"}"),
      target="abc",
    )
    assert_eq(err.describe(), "inspect: container not found: abc")
  }
}

///|
test "decode failures map onto the shared error type" {
  let over = engine_error_of_failure(
    op="logs",
    HttpDecodeError::BodyTooLarge(64 * 1024 * 1024),
  )
  guard over is BodyTooLarge(op="logs", limit=67108864) else {
    fail("expected BodyTooLarge, got \{over}")
  }
  let trunc = engine_error_of_failure(
    op="inspect",
    HttpDecodeError::Truncated("header block"),
  )
  guard trunc is TransportError(op="inspect", ..) else {
    fail("expected TransportError, got \{trunc}")
  }
  let malformed = engine_error_of_failure(
    op="inspect",
    HttpDecodeError::MalformedHeader("bad"),
  )
  guard malformed is MalformedResponse(op="inspect", ..) else {
    fail("expected MalformedResponse, got \{malformed}")
  }
}
