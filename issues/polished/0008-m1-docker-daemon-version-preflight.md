# [P1 / M1] Docker API version・daemon readiness の判定を追加

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

direct API 経路の利用前に `/_ping` と `/version` で daemon の稼働と API 互換性を判定し、daemon 停止・古い API・socket 誤接続を区別した診断を返す。無言の CLI fallback で隠さない。

## 背景

- upstream pinned revision は API version negotiation を行わず、unversioned path（`/containers/...` など）をそのまま使う。`GET /version` は [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) のリクエスト encode テストにしか現れない。
- MoonBit M0 は [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `detect_runtime()` が uname で runtime を選ぶだけで、daemon の稼働や機能差を確認しない。M1 で 0006 の transport と 0007 の decoder が揃う。
- 互換 Engine（Podman など）は API version と利用可能機能が異なる（0022 が互換境界を記録する）。CLI と direct API の移行方針は 0019 が持つ。

## 問題

- daemon への接続が成功しても、Docker 互換 daemon か、どの API version か、必要な機能を持つかを判定する手段がない。
- daemon 停止と socket 誤接続（別サービスが socket を占有）が同じ「接続失敗」に見える。
- エラーから CLI adapter 経由の失敗か direct API の失敗かを読み取れない。

## 目標

- `GET /_ping` で疎通、`GET /version` で daemon の version 情報を取得して事前診断する。
- 必須 API version を満たさない場合、pull / create などの副作用の前にエラーにする。
- daemon 停止・古い API・socket 誤接続（非 Docker サービス）を区別したエラー文言にする。
- CLI fallback と direct API のどちらを使ったか / 失敗したかをログとエラーで識別できる。
- unsupported option を無言で CLI fallback せず、0019 の規則に従って明示する。

## 対象外

- create / start などの API 本体（0010 以降）。
- CLI と direct API の最終的な移行方針・capability gate（0019）。
- Podman などの互換境界の記録（0022）。
- version 別 path prefix（`/v1.xx/...`）への切り替え実装。本 issue は判定と診断に限定する。
- Apple Container XPC（M2）。

## 提案する方針

- 0007 のデコーダと 0006 の transport の上に、新規 `docker_preflight.mbt`（仮）で `ping()` / `version()` を実装する。ファイル名・関数名は実装詳細として変更可。
- upstream に前例がないため、`/_ping` の本文や `/version` JSON のフィールド名（例: `ApiVersion` / `Version`）は実 Docker daemon の応答で確認してから固定する。判定は HTTP 200 を主とし、本文一致は補助にする。
- 必須 API version の値は、0010 以降で使う API を動かせる実 daemon で確認して 1 か所の定数にし、根拠を PR に記録する。比較方法（数値 parse か文字列か）も実装時に確定する。
- 失敗の分類:
  - 接続不可（socket 不存在 / 権限）→ daemon 停止の可能性として診断する（0006 の分類を利用）。
  - 接続可だが `/_ping` / `/version` が HTTP / JSON として解釈できない → Docker 互換 daemon ではない可能性として診断する。
  - version 情報は取れるが必須 API version 未満 → 古い API としてエラーにする。
- CLI fallback: 本 issue では「無言 fallback をしない」ことと経路の識別だけを実装する。実際に fallback する条件は 0019 に委ねる。
- ログ / エラーには socket path と経路（direct / CLI）を含め、秘密情報を含めない。

## 受け入れ条件

- [ ] Given mock daemon が `/_ping` 200 と正常な `/version` を返す, when preflight する, then 成功し、取得した version 情報が記録される。
- [ ] Given daemon が停止（socket 不存在 / 権限）, when preflight する, then daemon 停止の可能性がある接続エラーになり、CLI 失敗と混同しない。
- [ ] Given socket が非 Docker サービスに占有されている, when preflight する, then 「応答が Docker Engine API ではない」診断になる。
- [ ] Given 必須未満の API version を返す daemon, when preflight する, then 副作用前に「API version が古い」エラーになる。
- [ ] Given unsupported option, when direct 経路を試みる, then 無言 fallback せず識別可能なエラーになる（fallback の可否は 0019）。
- [ ] Given エラー / ログ, then 経路（direct / CLI）と socket path が識別できる。
- [ ] Given `moon check --target native --deny-warn` と `moon test --target native`, then PASS する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- mock daemon: 0006 の mock socket 基盤で固定応答（正常 / 古い version / 非 HTTP / 接続なし）を返す fixture を用意する。
- Linux Docker 実機: CI の docker ジョブで実 daemon の `/_ping` / `/version` を確認し、応答フィールドを fixture に反映する。実 daemon が無い間は「未実行」と記録する。
- Podman などの互換 Engine は 0022 の担当として未実行を明記する。

## リスク

- 実 daemon と version ごとに `/_ping` 本文が異なる → HTTP 200 を主判定にし、本文一致を必須にしない。
- 必須 version の決め打ちが互換 Engine を弾く → 値を 1 か所に集約し、0022 の互換記録と接続する。
- CLI fallback の無言化 → 経路識別をログとエラーの両方に実装し、0019 の規則に従う。
- preflight 自体のレイテンシ → ping / version の 2 リクエストに限定し、0018 の deadline 設計へ渡す。

## 変更履歴

`CHANGES.md` impact: no

判断理由: direct 経路の内部防御であり、公開 API からの到達と利用者向けの経路切替は 0010 / 0019 で生じるため、その時点の変更として記録する。

## 注記

- upstream は pinned revision では version negotiation を行わない。本 issue の事前診断は MoonBit 側の追加設計であり、互換 Engine の境界は 0022 と共同で確認する。
- 0006 の接続失敗分類と 0007 のレスポンス型を再利用する。0019 が fallback 方針、0018 が deadline を引き受ける。関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
