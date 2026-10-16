# [P0 / M3] Rust upstream と MoonBit の同一 fixture 比較基盤

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M3
Depends on: [0020](./0020-m1-linux-native-e2e.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

pinned upstream commit を oracle として Rust 版と MoonBit 版へ同一 fixture を実行し、exit / log / ports / copy / timeout の observable behavior を比較する基盤を作る。環境未実行を PASS に数えない。

## 背景

- 現行の受入は CI の Linux Docker smoke（[smoke/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt)）と未実行の Apple smoke（[smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt)）で、upstream の挙動を正とした比較の型がない。
- upstream には実行時の挙動を固定する E2E（`tests/container_linux.rs` / `tests/container_macos.rs` など）と property test（`pbt/`）がある。[docs/TESTCONTAINERS.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md) は API 単位の静的な比較表で、判定語彙（対応 / 部分対応 / 未配線 / 未反映 / 未実装）と意図的差分の記載方法（例: `WaitLogError::EndOfStream` の payload 型の差を意図的差分と明記）を持つ。
- [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) は "Expand upstream regression fixtures" を次の作業として挙げる。
- 依存の 0020（Linux daemon 直結 E2E）と 0032（Apple XPC E2E）が比較対象の実行基盤になる。

## 問題

- 「upstream ソースに該当コードがある」だけで parity を判定する余地が残っている。
- fixture ごとの環境（OS / arch / daemon / container version / revision）と結果の記録場所がない。
- 意図的差分（実装詳細の置き換えによる差分）と実装バグの FAIL が区別されない。
- 環境未実行の fixture が PASS と同じ扱いになり得る。

## 目標

- upstream commit `f68ba1ffed67` を固定 oracle にした比較手順が確立する。
- fixture は exit code / logs / published ports / copy / timeout を同一入力で比較する形で記述される。
- 各 fixture に upstream revision / MoonBit revision / 環境 / 実行結果（PASS / FAIL / 未実行）が記録される。
- 意図的差分は documented deviation として明示し、FAIL と区別する。
- 実行不能な環境の fixture は「未実行」として残り、PASS 件数に含めない。

## 対象外

- fixture 実行基盤そのものの実装（0020 / 0032）。本 issue は比較の定義と記録を担う。
- upstream revision の追跡手順（0053）。本 issue は固定 revision の比較のみ扱う。
- CI への組み込み（0052）。本 issue は fixture と記録形式まで。
- API 名の一致判定（docs/TESTCONTAINERS.md は静的な比較表として参照のみ）。

## 提案する方針

- fixture 記述形式を定義する（Markdown 表 + 実行手順。置き場所は docs/ 配下か issues/ 配下の専用ディレクトリかを実装時に決定）。
  - 列: fixture ID / 入力（image, cmd, env, ports, waits, timeout）/ oracle 操作（upstream のテスト名または手順）/ MoonBit 操作（smoke への追加など）/ 観測項目 / 期待 / upstream 結果 / MoonBit 結果 / 環境（OS, arch, Docker / Apple container version, 各 revision）/ 判定（PASS / FAIL / 未実行 / documented deviation）。
- 最初の fixture 群（比較可能性の高い順に追加する）。
  - exit: `sh -c "exit 3"` 相当の exit code と stderr。
  - log: readiness 文字列が stdout / stderr / either に現れる場合と来ない場合の待機結果と timeout 分類。
  - ports: 固定 published port の host port 解決と、動的割当の解決可否。
  - copy: copy_to 後の exec での内容確認、copy_file_from の内容一致。
  - timeout: startup timeout の超過時刻とエラー分類（0049 の分類と接続）。
- 実行は upstream 側を pinned checkout の `cargo test`（対象テスト名を fixture に記録）、MoonBit 側を native E2E / smoke で行い、実行コマンドと revision を fixture に貼る。
- 比較は observable な出力の一致で行い、内部型やエラーメッセージの完全一致は要求しない。文言差を許容する基準を先に書く（例: 分類が一致していれば文言差は許容、分類が異なる場合は FAIL）。
- upstream 側が実行できない場合（例: Apple 実機がない）は判定を曖昧にせず「未実行」と書き、PASS 件数に含めない。

## 受け入れ条件

- [ ] Given 新規 fixture を追加する, when 記録する, then upstream revision / MoonBit revision / 環境 / 結果の 4 項目が埋まっている。
- [ ] Given exit / log / ports / copy / timeout の各分類, when Linux Docker 実機で比較する, then upstream と MoonBit の観測結果が記録される。
- [ ] Given 差分が意図的な設計差, when 判定する, then documented deviation と理由（upstream docs / issue 番号）が付き、FAIL と区別される。
- [ ] Given 環境がない fixture, when 一覧を確認する, then 「未実行」と明示され、PASS に含まれない。
- [ ] Given 比較の実行, when revision を確認する, then pinned `f68ba1ffed67` と記録が一致する。
- [ ] Given 既存の smoke / E2E, when 変更後に実行する, then 壊れない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- `moon run smoke --target native` で MoonBit 側 fixture の最小実走を確認する（Docker 実機、CI の docker-e2e ジョブ）。
- upstream 側は pinned checkout で対象テスト（例: `cargo test --test container_linux`）を実行し、テスト名と結果を fixture に記録する。対象テスト名は実装時に確定する。
- 本 issue の完了には少なくとも 1 分類（exit）の Linux Docker 比較結果を残す。
- Apple 側 fixture は物理 Mac が必要なため「未実行」と理由を記録し、0032 の受入後に埋める。GitHub-hosted macOS runner の compile では代替しない（[docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の理由）。
- PASS / FAIL / 未実行を混同せず、証跡（コマンド・出力・revision）を残す。

## リスク

- 実装詳細の差分を observable の差分と混同する。判定は fixture の観測項目に限定し、分類の一致を必須にする。
- Rust 側 fixture の実行環境（cargo / Docker）が MoonBit CI と異なる。環境列を必須にして追跡可能にする。
- documented deviation が増えると比較が形骸化する。理由と解消条件（例: upstream の変更で解消したら再判定）を必ず書く。
- 記録が属人化する。fixture の列と記録先を固定し、0052 の artifact / 証跡方針へ接続する。
- ロールバック: fixture と記録の追加のみで、既存 CI の挙動を変えない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)、[docs/TESTCONTAINERS.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md)、upstream `tests/`。
- 関連: 0020 / 0032（実行基盤）、0052（CI と証跡）、0053（revision の扱い）。0001 の証跡方式（前後の一覧とコマンドログ）を踏襲する。
- 「Rust ソースの存在で parity を判定しない」原則を本 issue が具現化する。0049 の分類表と接続し、timeout / not found 系の fixture は同じ語彙で判定する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
