# [P0 / M1] Docker HTTP/1.1 応答・chunked・stream decoder を実装

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0006](./0006-m1-docker-unix-socket-transport.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の HTTP/1.1 レスポンスを、分割到着・chunked・close-delimited を含めて 1 応答へデコードする sans-io 状態機械を実装する。壊れた入力と上限超過は fail closed（成功扱いしない）にする。

## 背景

- upstream は [src/core/client/http_decode.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/http_decode.rs) の `ResponseAccumulator` が `shiguredo_http11` の `ResponseDecoder` を包み、I/O とデコードを分離する。1xx は破棄して最終応答を待ち、`Content-Length` / chunked が未完のまま EOF ならエラー、close-delimited は EOF を終端とする。
- ボディ上限は呼び出し側が指定し、exec 出力・pull 進捗・archive などで `BodyLimit::Error(DOCKER_RESPONSE_BODY_LIMIT)`（`64 * 1024 * 1024` = 64 MiB）を共有する。判定は `>` で、ちょうど上限は成功。
- [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) の `read_http11_response` は `acc.read_buf_size()` 分ずつ読み続け、完了までループする。ボディ完了後に keep-alive で待たない（`Connection: close` 前提と整合）。
- MoonBit 側には相当する HTTP パーサが存在しない。

## 問題

- transport（0006）がバイト列を返せても、status / header / 本文境界を解釈できなければ API 応答を扱えない。
- Docker API は chunked や close-delimited（exec start など）を返すため、read-to-end だけでは完了判定と異常検出を両立できない。
- 分裂パケットでのヘッダ途中 EOF、Content-Length 矛盾、不正 chunk を検出する設計がない。

## 目標

- status line / header / body を Content-Length / chunked / close-delimited / ボディ無しの各ケースで正しくデコードする。
- 入力が任意境界で分割されても、同一の応答になる。
- 壊れた chunk、矛盾する長さ、ヘッダ未完 EOF を fail closed でエラーにする。
- 一括取得経路で 64 MiB を超えるボディを成功扱いしない（ちょうど 64 MiB は成功、upstream と同じ `>` 境界）。
- 1xx 中間応答を破棄して最終応答を返す。

## 対象外

- socket の接続と送受信（0006）。
- status code の意味分類とエラー型への写像（0017）。
- create / exec / pull など API ごとの用途（0009–0013）。
- follow ストリームの逐次配信と backpressure（0013、0040）。

## 提案する方針

- 新規 `http_decode.mbt`（仮）に upstream の `ResponseAccumulator` 相当（`feed(bytes) -> 完了?` と head / body の取得）を実装する。ファイル名・型名は実装詳細として変更可。
- 扱う本文種別: ボディ無し（204 など）、`Content-Length`、chunked、close-delimited（EOF 完了）。chunked は chunk サイズ行・chunk データ・最終 chunk・トレーラを解釈する。Tunnel 型など特殊な種別は必要になった時点で 0012 以降に追加する。
- エラー分類: ヘッダ未完 EOF、Content-Length 未完 EOF、chunked 未完 EOF、不正 chunk サイズ、矛盾する長さ、上限超過。上限超過の文言は upstream の `output exceeds {max} bytes limit` 相当とし、`>` 境界（ちょうどは成功）を守る。
- ボディ上限値は呼び出し側指定とし、既定 64 MiB（upstream `DOCKER_RESPONSE_BODY_LIMIT` と同じ）をコード上の 1 か所に定数化する。
- 1xx は破棄して次の応答を読み直す（upstream の再 decode 方式）。
- ヘッダ行長・ヘッダ数・chunk サイズ行にも上限を設ける。値は upstream が使う `shiguredo_http11` のデコーダ既定値を確認した上で決める（未確認の値を断定しない）。

## 受け入れ条件

- [ ] Given `Content-Length: 5` + `hello`, when 全境界分割（1 バイトずつ）で feed する, then 1 応答になり body が `hello` になる。
- [ ] Given chunked 応答, when 任意境界で分割して feed する, then 連結後の body が一致し、最終 chunk とトレーラで完了する。
- [ ] Given `Content-Length: 5` に対し body が 2 バイトで EOF, then エラーになり部分応答を返さない。
- [ ] Given 長さヘッダ無しの close-delimited 応答, then EOF で完了として扱う。
- [ ] Given 64 MiB + 1 バイトのボディ, then 上限エラーになる。ちょうど 64 MiB は成功する。
- [ ] Given 不正な chunk サイズ行や矛盾する長さ, then エラーになり、部分的な body を成功として返さない。
- [ ] Given 1xx 応答の後に最終応答, then 最終応答だけを返す。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: 固定バイト列を全境界で分割して feed するテストと、upstream `http_decode.rs` のテスト（未完 EOF、1xx、上限ちょうど / 超過、複数 chunk 跨ぎ、204）に対応する negative テストを移植する。
- transport と接続した daemon E2E（実 Docker の chunked / close-delimited 応答読み取り）は 0006 / 0008 と併せて実施し、実 daemon が無い間は「未実行」と明記する。
- Apple 実機は対象外（M2）。

## リスク

- ヘッダ解釈の差（大文字小文字、余分な空白、複数値）で daemon と食い違う → RFC 9110 に沿わせ、実 daemon の応答 fixture で確認する。
- 極端に大きいヘッダ / chunk でメモリを使い切る → 行・ヘッダ・chunk サイズの上限を設け、超過はエラーにする。
- 上限判定の誤り（`>=` と `>`）で 64 MiB の応答を取り逃す / 通しすぎる → upstream と同じ `>` 境界をテストで固定する。
- close-delimited と接続断の区別漏れ → 「EOF は完了、未完の長さ付き EOF はエラー」をテストで固定する。

## 変更履歴

`CHANGES.md` impact: no

判断理由: 内部デコーダの追加で公開 API を変更しない。利用者に見える影響は 0009 以降の API 実装で生じる。

## 注記

- upstream 参照: `ResponseAccumulator` / `BodyLimit`（1xx 破棄、close-delimited、上限文言）、`read_http11_response`、`DOCKER_RESPONSE_BODY_LIMIT = 64 * 1024 * 1024`、`>` 境界。
- 上限は将来 0013 / 0040 の follow ストリームと整合させる。deadline の一元化は 0018。関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
