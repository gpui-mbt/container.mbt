# [P0 / M1] Node/Rust に依存しない Docker Unix socket transport

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: なし
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

MoonBit native から Docker Engine API の Unix domain socket（既定 `/var/run/docker.sock`）へ直接接続し、docker CLI を起動せずに HTTP リクエストを送受信できる transport 層を作る。まず `GET /_ping` に到達できることを完了条件にする。

## 背景

- M0 は `@shell.Cmd` で `docker` CLI を子プロセス実行する（[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)）。upstream Linux は `DockerClient` が `UnixStream::connect` で socket に接続する（[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)、`DEFAULT_DOCKER_SOCKET = "/var/run/docker.sock"`）。
- upstream は connect の前にリクエストを encode し、`Host: localhost` と `Connection: close` を付け、書き込みの半閉じはしない（dockerd / Docker Desktop が 500 を返すため）。読み取りは `read_http11_response` で完了まで読み、keep-alive での待ちに入らない。
- [moon.pkg](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/moon.pkg) は `moonbitlang/async` / `process` / `shell` のみを import しており、socket 接続の使用実績はない。

## 問題

- `moonbitlang/async@0.22.4` が Unix domain socket のクライアント接続 API を提供するか未調査で、無い場合に必要になる native C FFI + native-stub の構成も未整備。
- 接続失敗（socket 不存在・権限拒否）を区別して返す設計がない。
- FD / 接続のライフサイクル（成功・失敗・取消時に閉じられるか）が未設計。

## 目標

- docker CLI を起動せず、`/var/run/docker.sock` へ接続して `GET /_ping` の応答バイト列を取得できる。
- socket path をテストから注入できる（mock socket 用）。
- connect 失敗を「不存在」「権限拒否」「その他 IO」に分類したエラーで返す。
- 接続と FD が成功 / 失敗 / 取消の全経路でリークなく閉じる。
- 実装手段（`moonbitlang/async@0.22.4` の API か C FFI + native-stub か）を調査で決定し、根拠を PR に記録する。

## 対象外

- HTTP 応答のデコード（0007）。
- create / start / pull などの API（0009、0010）。
- deadline・取消・再試行の一元化（0018）。本 issue は transport 単体に限定する。
- Apple Container XPC（0023–0032、M2）。Linux の socket のみ扱う。

## 提案する方針

- 最初に `moonbitlang/async@0.22.4` の公開 API を調査する。Unix domain socket の connect / read / write が可能ならそれを transport に使い、不可なら native C FFI + native-stub で Unix domain socket の接続と読み書き、close を薄くラップする。`native-stub` の設定と Linux 限定のビルド条件は実装時に決定する。
- 新規 `docker_transport.mbt`（仮）に接続とバイト送受信の最小境界を置く。ファイル名・型名・関数分割は実装詳細として変更可。リクエストの組み立て（method / path / body / headers）は 0007 と共通の純粋型にする。
- 既定 socket path は upstream と同じ `/var/run/docker.sock` とし、テスト用に注入可能にする。`DOCKER_HOST` や Docker context の解決は行わない（0019 の移行方針で扱う）。
- connect 失敗の分類は errno 相当の情報から「不存在」「権限拒否」「その他」に分ける。具体的な照合方法は実装手段（async API / C FFI）に依存するため実装時に確定する。
- FD の close を 1 か所に集約し、エラー・取消経路でも必ず通す。無期限にブロックしないよう暫定の読み書き上限（回数または時間）を設ける（恒久的な deadline 設計は 0018）。
- 1 接続 1 リクエスト（upstream と同じ `Connection: close` 前提）とし、接続の再利用はしない。書き込みの半閉じは upstream と同じく行わない。

## 受け入れ条件

- [ ] Given Linux の稼働 Docker daemon, when transport で `GET /_ping` を送る, then 応答（HTTP 200 相当）のバイト列を受け取り、docker CLI プロセスを起動していない。
- [ ] Given 存在しない socket path, when connect する, then 「不存在」と分類されたエラーが返る。
- [ ] Given 読み取り権限のない socket, when connect する, then 「権限拒否」と分類されたエラーが返り、不存在と混同されない。
- [ ] Given mock の Unix socket server, when 1 リクエストを送る, then 送信バイト列が期待どおりで、応答を受信できる。
- [ ] Given 送信途中の失敗・読取失敗・取消, then 接続が閉じられ、`/proc/self/fd` などでリークが観測されない。
- [ ] Given `moon check --target native --deny-warn` と `moon test --target native`, then PASS する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- mock: テスト用の Unix socket listener を立て、固定応答を返す。listener を MoonBit 側で用意するか外部 fixture にするかは実装手段の決定に合わせ、テスト方法は実装時に確定する。
- Linux Docker 実機: CI の docker ジョブで実 daemon の `/_ping` 到達を確認する。実 daemon が使えない環境では「未実行」と記録する。
- FD リーク検査: 反復接続後の `/proc/self/fd` 数を Linux で確認する。
- Apple 実機は対象外（M2）。

## リスク

- `moonbitlang/async@0.22.4` に Unix socket が無く C FFI 追加でビルド構成が複雑化する → target native / Linux 限定に閉じ、`moon.pkg` の変更を小さく保つ。決定と根拠を PR に記録する。
- ブロッキング read で無期限に待つ → 暫定上限を設け、0018 で一元化する。
- FD リーク → close 経路を 1 か所に集約し、失敗注入で検証する。
- CLI 経路との混在で挙動が分かりにくくなる → 本 issue は transport のみを追加し、公開 API（`start` など）には接続しない。切替は 0019 で扱う。

## 変更履歴

`CHANGES.md` impact: no

判断理由: 公開 API を変更しない内部基盤。利用者に見える切替は 0010 / 0019 以降で扱う。

## 注記

- upstream 参照: `DockerClient::detect`（socket path の既定値）、リクエスト encode（`Host: localhost` / `Connection: close` / 半閉じ禁止）、`read_http11_response`、`remove_blocking` の 60 秒読み書きタイムアウト（`DOCKER_STREAM_TIMEOUT`）。長時間ブロックし得る exec start などにはタイムアウトを付けない upstream の使い分けを 0018 で引き継ぐ。
- 実装手段の決定（async API / C FFI）を完了条件に含め、決定結果をこの issue のコメントまたは PR 記述に残す。
- 0007 が本 transport の上に HTTP デコーダを載せる。0018 が deadline・取消を一元化する。関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
