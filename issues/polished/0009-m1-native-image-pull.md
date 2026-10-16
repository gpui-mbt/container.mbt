# [P0 / M1] Docker Engine API の image pull と progress/error を実装

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の `POST /images/create` で image を pull し、JSON Lines の progress と error を処理する。ローカルの既存 image は再 pull せず、404 / 認証 / timeout を区別し、秘密情報をログに出さない。

## 背景

- upstream `DockerClient::pull_image`（[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)）は descriptor を `split_pull_reference` で `fromImage` / `tag` に分け、`/images/create?fromImage=...&tag=...[&platform=...]` へ percent-encode して POST する。
- pull 進捗は JSON Lines。`check_pull_stream_errors` が各行を object として parse し、非空の `error` または `errorDetail.message` があればエラー、空行は無視、非 object / 不正 JSON / 非 UTF-8 は JSON エラー、空ボディは成功として扱う。
- status 400 以上は `pull_error_message` がボディの `message` を含めて `failed to pull image {descriptor}: {status}: {message}` 形式で報告する（401 の `unauthorized: ...` を含む）。
- pull policy: 先に `resolve_image_descriptor`（`GET /images/{name}/json`、404 = `ImageNotFound`）で解決し、`ImageNotFound` のときだけ pull → 再 resolve する（`resolve_or_pull_linux`、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）。amd64 の強制 pull は macOS 専用挙動で本 issue の対象外。
- ボディ上限は `BodyLimit::Error(DOCKER_RESPONSE_BODY_LIMIT)`（64 MiB）。registry 認証（`X-Registry-Auth`）は [src/core/client/registry_auth.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/registry_auth.rs) が担当し、MoonBit 側は 0016 が移植する。
- MoonBit 側に pull は無く、CLI `docker run` の暗黙 pull に依存している。

## 問題

- direct API 経路（0010 以降）で image を準備できない。
- 404 と認証失敗（401）と timeout の区別、pull stream 内の error 検出が無い。
- 秘密情報をログに出さない方針が定義されていない。

## 目標

- `alpine:3.20` のような指定バージョンの pull が docker CLI なしで成功し、解決済み image を create / start 経路（0010）へ渡せる。
- 404 / 認証 / timeout を区別したエラーを返す。
- pull stream の progress は読み捨て可能とし、非空 `error` / `errorDetail.message` は失敗として返す。
- 既にローカルにある image は pull せず resolve のみで済む。
- エラー / ログに認証情報（`X-Registry-Auth` の中身、config.json の auth）を出さない。
- pull policy（resolve 成功なら pull しない、404 のとき 1 回だけ pull）を文書化する。

## 対象外

- registry auth の解決と送信（0016）。
- create / start 本体（0010、0011）とその E2E（0020）。
- progress の UI 表示や LogConsumer 連携（0040）。
- Apple XPC の image pull（0025、M2）と amd64 強制 pull（macOS 専用挙動）。

## 提案する方針

- 新規 `docker_image.mbt`（仮）に `resolve` と `pull` を実装する。ファイル名・関数名は実装詳細として変更可。0006 の transport、0007 の decoder、0008 の preflight を利用する。
- reference 分割は upstream `split_pull_reference` と同じ規則にする: `@` 以降（digest）を優先し、tag は最後の `/` より後だけを見る、tag が空なら `latest` に正規化する。`fromImage` / `tag` / `platform` は percent-encode する（upstream と同じく `/` も encode し、form の `+` は使わない）。
- resolve: `GET /images/{name}/json`。200 = 既存、404 = `ImageNotFound` 相当、その他の 4xx / 5xx はそのままエラー。`ImageNotFound` のときだけ pull を 1 回呼び、成功後に再 resolve する（upstream `resolve_or_pull_linux` と同じ「pull は呼び出し側で 1 回」の規則）。
- pull: `POST /images/create?fromImage=...&tag=...[&platform=...]`、ボディなし。status 400 以上はボディの `message` を含むエラー（401 は認証失敗と分類できる文言）。200 は JSON Lines を 1 行ずつ parse し、非空 `error` / `errorDetail.message` で fail、空行 / progress / `aux` は無視、非 object / 不正 JSON / 非 UTF-8 はエラーにする。
- ボディ上限は 64 MiB（upstream `DOCKER_RESPONSE_BODY_LIMIT` と同じ）とし、超過時は image 名を付けた文脈付きエラーにする。
- 秘密情報: 本 issue では auth ヘッダを送らない（config.json の読み込みは 0016）。0016 で追加されてもログ / エラー本文にヘッダ値を出さない方針をコードコメントとテストで固定する。
- timeout: 0018 の一元化前に有界の `timeout_ms` で打ち切る。値は実装時に決定し、1 か所に定数化する。中断時に接続が閉じることは 0006 の契約に依存する。
- pull policy は `docs/PORTING.md` または新規コードの doc コメントに明記する。

## 受け入れ条件

- [ ] Given Docker 実機で `alpine:3.20` がローカルに無い, when resolve → pull を実行する, then `/images/create` が成功し再 resolve が成功する（docker CLI 未使用）。
- [ ] Given 既にローカルにある image, when resolve する, then pull は呼ばれない（リクエストログで確認）。
- [ ] Given 存在しない image, then 404 が「image が見つからない」として分類される。
- [ ] Given 認証が必要な private repository, then 401 / 認証失敗が 404 と区別され、エラーに認証情報が含まれない。
- [ ] Given pull stream の途中または末尾に非空の `error` / `errorDetail.message`, then 行位置に関係なく失敗として返る。
- [ ] Given pull stream に非 object / 不正 JSON 行, then JSON エラーとして失敗する。空行のみのボディは成功する（upstream と同じ）。
- [ ] Given pull が timeout, then 有界時間で失敗し、接続と資源が残らない。
- [ ] Given pull 後の CLI なし start, then 0010 の実装と結合した受入（0020）で確認する。0010 未完了の間は「未実行」と記録する。
- [ ] Given `moon check --target native --deny-warn` と `moon test --target native`, then PASS する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 純粋テスト: reference 分割（`localhost:5000/nginx:latest`、digest 付き、tag 空、`@` 空、`nginx`）と pull stream の error 検出（非空 error、errorDetail のみ、空 error は無視、非 object / 不正 JSON / 非 UTF-8 はエラー）を wbtest で固定する。upstream のテストケースを移植する。
- mock daemon: 0006 の mock socket 基盤で `/images/create` の正常 / 404 / 401 / stream error / 上限超過の fixture を返す。
- 実 Docker: CI の docker ジョブで `alpine:3.20` の resolve → pull を direct API で確認する。実 daemon が無い間は「未実行」と記録する。
- timeout と中断時の資源確認は 0006 の FD 検査を再利用する。

## リスク

- private registry への認証送信を先行実装すると秘密漏洩につながる → 0016 に分離し、本 issue では auth を送らない。
- progress 行の大量受信でメモリを消費する → 64 MiB 上限と行単位処理（全行を保持しない）で抑える。
- reference 分割の互換差で誤った image を pull する → upstream の分割テストを fixture として移植する。
- timeout 値の決め打ちが遅い registry を誤って切る → 値を 1 か所に集約し、0018 の deadline 設計と接続する。
- CLI の暗黙 pull と direct pull の二重経路が混在する → 0019 の切替方針で経路を明示する。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API による image pull（reference 正規化、resolve / pull policy、pull ストリームのエラー処理）を追加する

## 注記

- upstream 参照: `pull_image` / `split_pull_reference` / `check_pull_stream_errors` / `pull_error_message` / `resolve_image_descriptor`（docker_client.rs）、`resolve_or_pull_linux`（async_runner.rs）、`ImageConfig`（[src/core/client/image_config.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/image_config.rs) は 0010 の create で使う）、registry auth（0016 が移植）。
- CLI の暗黙 pull と並存するため、0020 の E2E と 0019 の移行方針で経路を明示する。関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
