# [P1 / M3] 公開エラー型と失敗分類の一貫性を検証

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0017](./0017-m1-engine-http-errors.md), [0024](./0024-m2-xpc-protocol-contract.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

CLI の文字列エラーと Engine / XPC のエラーを upstream の `Error` / `ClientError` 相当の公開分類へ統合し、missing image / container / path、auth 失敗、timeout を adapter 間で一貫して識別できるようにする。

## 背景

- upstream の `Error` は `Client(ClientError)` / `WaitContainer(WaitContainerError)` / `PortNotExposed { id, port }` / `Exec(ExecError)` / `Io` / `Other` の 6 分類（[src/core/error.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/error.rs) 19–37 行付近）。`ClientError` は `XpcConnect` / `Xpc` / `XpcTimeout` / `ImageNotFound` / `ContainerNotFound` / `ContainerPathNotFound` / `Configuration` / `Json` / `Other`（105–140 行付近）。Display 文言も定義済み（132–137 行付近）。
- upstream の Docker 経路は 404 のボディ message で `ContainerPathNotFound` と `ContainerNotFound` を区別し、pull の 401 unauthorized は診断できるよう message を含める（[docs/TESTCONTAINERS.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md) 62 行付近、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) 149 行付近・2292–2300 行付近）。
- 現行 MoonBit は [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `fail("container run failed (exit N): stderr")` 等の文字列エラーで分類がない（91 / 97–99 / 126–127 / 151–152 / 157–159 / 170–177 / 183–192 / 203 / 216–224 / 234–235 / 249 行付近）。
- 依存: 0017（Engine HTTP のステータス分類）と 0024（XPC の型・エラー契約）が語彙の基礎になる。本 issue は両者を統一し、CLI adapter の写像を加える。

## 問題

- 呼び出し側が missing image / container / path と auth 失敗 / timeout を文字列マッチなしで分岐できない。
- CLI adapter のエラーは exit code と stderr の断片のみで、機密情報の redact 方針がない。
- 同一の失敗（例: コンテナ不存在）が adapter ごとに異なる文言・分類になり得る。
- エラー経路の所有資源回収（0001 / 0042）と分類の関係（回収失敗で元エラーを上書きしない）が未定義。

## 目標

- upstream 相当の公開エラー分類が MoonBit に存在し、既存の `raise` 文字列から分類付きエラーへ移行（または包む）される。
- missing image / container / path、auth 失敗、timeout を識別できる。
- password / token / registry 認証ヘッダ値などの機密情報がエラー文字列・ログに含まれない。
- Docker CLI / Linux Engine / Apple XPC で同じ分類名へ写像する表がある。
- エラー時も所有資源の回収方針が一貫し、回収失敗で元エラーが上書きされない。

## 対象外

- HTTP パースとステータス判定の実装（0017）、XPC プロトコル契約（0024）、registry 認証の実装（0016）。
- cleanup の実装そのもの（0001 / 0021 / 0042）。本 issue は分類と回収の整合だけを扱う。
- retry / deadline 方針（0018）。

## 提案する方針

- 新規 `errors.mbt`（名称案。実装詳細として変更可）に公開エラー型を追加する。MoonBit で実現可能な形（公開 enum と `suberror` 等の error 型）を実装時に選定する。
  - 分類は upstream の語彙に対応させる: Client / WaitContainer / PortNotExposed / Exec / Io / Other。
  - Client の内訳: connect / protocol / timeout / image not found / container not found / container path not found / configuration / json / other。
  - 名前と Display 文言は upstream `error.rs` の variant / 文言を基準にし、公開言語（英語 / 日本語）は実装時に既存 README とメッセージの方針へ合わせる。
- adapter 写像表を作る（adapter × 原因 × 期待分類 × 根拠 × 観測）。
  - Docker CLI: exit code + stderr。`docker pull` の not found / unauthorized などの判定文字列は実機ログで確認して表に固定し、判定不能は `Other` として raw stderr を保持する。
  - Engine（0017）: HTTP 404 + ボディ message で path / container を区別、401 / 403 を auth、deadline 超過を timeout に写像する。
  - XPC（0024）: `XpcConnect` / `Xpc` / `XpcTimeout` をそのまま写像する。
- 機密 redact: registry 認証（`X-Registry-Auth` ヘッダ値）や password / token をエラー文字列に含めない。CLI stderr をそのまま包む経路でも秘密が出力されないことをテストで固定する。エラー生成を 1 箇所に集約する。
- 所有資源回収との整合: 分類は操作の失敗理由を表し、回収（0001 の label 所有証明付き削除、0042 の契約）の成否で上書きしない。回収結果は診断として付記できるが、返る分類は元エラーのままにする。
- 互換: 公開 API の `raise` 効果は維持し、既存呼び出しの `catch { _ => ... }` を壊さない。分類へのアクセス手段は後方互換の追加として提供する。

## 受け入れ条件

- [ ] Given 存在しない image, when pull / start する, then image not found 分類で返る（Engine 経路）。
- [ ] Given 存在しない container id, when exec / logs / rm する, then container not found 分類になる。
- [ ] Given コンテナ内の存在しない path, when copy_file_from / copy_to する, then container path not found 分類になり、container not found と混同しない。
- [ ] Given 認証失敗する registry, when pull する, then auth 分類になり、password / token / 認証ヘッダ値がメッセージに含まれない。
- [ ] Given 応答しない daemon / XPC, when 操作する, then timeout 分類になる。
- [ ] Given Docker CLI / Engine / XPC で同一種の失敗, when 分類を比較する, then 写像表の同一分類になる。
- [ ] Given エラー経路で所有コンテナの回収も失敗する, when エラーを受け取る, then 分類は元の失敗のまま（回収失敗で上書きされない）。
- [ ] Given 既存の `fail` 文字列を catch する呼び出し, when ビルド・実行する, then 壊れない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 写像表の各ケース（成功 / 失敗の両方向）、Display に password や token が現れないこと、回収失敗時に分類が変わらないことを検証する。
- Linux Docker 実機（CI の docker-e2e ジョブ）: 存在しない image の pull、不存在 id への exec、不存在 path の copy を E2E で実行し、分類表を実測で更新する。
- Apple 実機: XPC の connect / timeout / not found を 0032 の受入時に確認する。物理 Mac がない間は「未実行」と理由を記録する。
- 分類表（adapter × 原因 × 期待分類 × 観測結果 × 日付）を issue または docs に残す。
- PASS / FAIL / 未実行を混同しない。擬似テストだけで実機 E2E を代替しない。

## リスク

- エラー型の導入で API 互換性を壊す危険。既存 `raise` シグネチャを維持し、分類は追加として提供する。
- CLI stderr からの分類は脆弱。ヒューリスティックの対象文字列と限界を表に明記し、判定不能は raw 保持の `Other` へフォールバックする。
- redact 漏れ。エラー生成を 1 関数に集約し、秘密値を含む入力のテストを常時回す。
- 回収失敗の付記が分類を変えると、呼び出し側の分岐が壊れる。付記はメッセージのみに限定する。
- ロールバック: エラー層の追加と既存 `fail` の包み替えに限定。文言変更が生じる場合は wbtest / E2E で回帰を固定してから切り替える。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] 公開エラー分類と adapter 間の失敗写像表を追加し、機密情報の redact を保証する

## 注記

- 参照: [src/core/error.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/error.rs)、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)、[docs/TESTCONTAINERS.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md)。
- 関連: [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)、0017 / 0024 の分類語彙を統一する。0016（registry 認証）と 0001 / 0042（回収）の契約に依存する。
- 証跡として分類表と実測ログ（秘密を含まない）を issue または docs に残す（0050 / 0052 の証跡方針と整合）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
