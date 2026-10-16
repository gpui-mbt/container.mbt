# [P2 / M3] Mac 専用 kernel/ssh/masked/readonly path オプション

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M3
Depends on: [0024](./0024-m2-xpc-protocol-contract.md), [0026](./0026-m2-xpc-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Apple Container 専用の `with_kernel` / `with_ssh` / `with_masked_paths` / `with_readonly_paths` を追加し、XPC 経路への反映可否を実機で確認した上で、Linux では明示 non-supported のままにする。

## 背景

- upstream `ImageExt`（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)）は `with_ssh`（173 行付近）、`with_masked_paths`（175–185 行付近、Apple container 1.2.0 以上）、`with_readonly_paths`（187–197 行付近、同）、`with_kernel`（199–230 行付近）を公開する。masked / readonly path は「未指定 = ランタイム既定、空リスト = 既定の無効化、明示リスト = 既定を完全に上書き、複数回呼び出しは上書き」（468–486 行付近。`container_cfg.rs` 804–885 行付近のテストが根拠）。
- upstream の macOS 経路は `containerCreate` の `ssh` / `maskedPaths` / `readonlyPaths` に載せ（[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs) 269–276 行付近）、`with_kernel` は既定カーネル取得をせず `Kernel` JSON を組み立てて渡す（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs) の `kernel_json` 1296 行付近、`get_default_kernel` 532 行付近）。
- upstream は kernel path を pull / resolve より前に検証する（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs) 100–104 行付近）。絶対パスであること、UTF-8 であること、実ファイルであることを確認し、満たさなければ `ClientError::Configuration` を返す（684–709 行付近）。
- Linux では 4 option とも未対応で、start 時に明示エラーにする（async_runner.rs の `linux_unsupported_request_reason` 657–675 行付近）。[src/lib.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/lib.rs) 42–43 行付近にも「未対応 (start 時に明示エラー)」と明記されている。
- 現行 MoonBit に該当 option はなく、Apple 経路は M0 CLI adapter のみ（[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) は Apple Container を "CLI adapter only, unverified" とする）。

## 問題

- 現行 API では Apple 固有の安全性設定（masked / readonly path、ssh、kernel）を表現できない。
- Linux / Apple CLI adapter で渡された場合に黙って無視される余地がある（silent ignore 禁止は 0004 の方針）。
- `container run` がこれらの設定を提供するか未検証で、CLI adapter で再現できる範囲が不明。
- kernel path の検証（絶対パス / UTF-8 / 実ファイル、pull より前の fail-fast）がない。
- masked / readonly path の「未指定 / 空リスト / 明示リスト」の区別が型で保証されず、既定マスクの意図しない無効化につながり得る。

## 目標

- 4 option の型付き API が追加され、値の意味論（未指定 / 空 / 明示、後勝ち）が upstream と一致する。
- macOS XPC 経路で反映、または実機検証の結果に基づく明示エラーになる。Linux / Apple CLI adapter で未対応のものは副作用前に明示エラーになる。
- kernel path は pull / resolve より前に検証される。
- 秘密 path / ホスト path が意図せず容器へ公開されない。
- 非対応機能が silent ignore されない。

## 対象外

- XPC のプロトコル契約・create / start そのもの（0024 / 0026）。本 issue は option 層・検証・fail-fast を担う。
- masked / readonly path の E2E 受入は 0032 の実機試験に含める。
- Linux の能力設定（privileged / cap / shm / init）は 0046。
- ssh 転送の実装可否は「Apple container の側に何があるか」を実機で確認した結果で判断し、本 issue では API と拒否契約までを扱う。

## 提案する方針

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) に `ssh : Bool`、masked / readonly path のリスト、`kernel_path : String?` 相当のフィールドを追加する（内部名・表現は実装詳細として変更可）。masked / readonly path は「未指定」と「空リスト」を型で区別できる形にする。
- API は upstream と同義にする。
  - `with_ssh()`: true にする。
  - `with_masked_paths(paths)` / `with_readonly_paths(paths)`: 呼び出しごとに後勝ちでリスト全体を置換。空配列は既定の無効化として保持する。
  - `with_kernel(path)`: 後勝ちで上書き。
- adapter ごとの扱い。
  - Apple XPC（M2 完了後）: `containerCreate` の `ssh` / `maskedPaths` / `readonlyPaths` へ配線する。kernel は `get_default_kernel` を呼ばず `Kernel` JSON（path / platform / commandLine）を組み立てて渡す。
  - Apple CLI adapter: `container run` の同等フラグ・設定の有無を実機で確認する。確認できない option は `start` 前の明示エラーにする。
  - Linux / Docker: option 指定があれば常に `start` 前の明示エラーにする（upstream の文言方針 `with_ssh() is not implemented on Linux` 等に倣う）。CLI adapter でも独自翻訳しない。
- 検証順序（副作用の前、1 回だけ）。
  - kernel: 絶対パスでなければ fail、非 UTF-8 相当は fail、実ファイルでなければ fail（upstream `validate_kernel_path` と同じ）。
  - masked / readonly path: upstream は個々の path 文字列を検証しない（そのまま XPC へ渡す）。MoonBit 側の拒否ルール（空文字・制御文字など）の要否は Apple 実機で受け付け挙動を確認して決定し、ホスト側 path を意図せず公開する設定にならないことを確認する。
- 「未指定 / 空リスト / 明示リスト」の意味論と後勝ちを wbtest で固定する。

## 受け入れ条件

- [ ] Given `with_masked_paths([])`（空リスト）, when Apple XPC で start する, then `maskedPaths: []` が送信され既定マスクが無効化される（0024 の契約単体テストで確認）。
- [ ] Given `with_kernel("/abs/vmlinux")`, when Linux で start する, then pull / resolve より前に明示エラーになる。
- [ ] Given 相対パスの kernel, when macOS で start する, then resolve / pull より前に設定エラーになる。
- [ ] Given `with_ssh` / masked / readonly path を指定, when Apple CLI adapter で start する, then 未対応なら副作用前にエラーになり、黙って無視されない。
- [ ] Given 2 回の `with_masked_paths`, when 設定値と送信内容を確認する, then 最後のリストだけが有効になる（後勝ち）。
- [ ] Given 既定マスクを持つ環境, when option を一度も指定しない, then ランタイム既定が維持される（空リスト指定と区別される）。
- [ ] Given 既存 API のみを使う呼び出し, when ビルド・実行する, then 挙動が変わらない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 未指定 / 空 / 明示の区別と後勝ち、Linux の明示エラー、kernel path 検証の順序（pull 前に fail すること）を検証する。
- 物理 Mac 実機: maskedPaths / readonlyPaths / ssh / kernel の送信内容を Apple XPC 経路（0026 完了後）と `container inspect` で確認する fixture を `smoke_apple` に追加する。Apple container 1.2.0 以上の version 要件を記録する。
- Linux 実機（CI の docker-e2e ジョブ）: 4 option すべてが start 前に fail し、pull / create の副作用が起きない（image 一覧・コンテナ一覧が不変）ことを確認する。
- 物理 Mac が使えない間は「未実行」と理由を記録し、0032 の実機受入と併せて実施する。
- PASS / FAIL / 未実行を混同しない。擬似テストだけで Apple 実機 E2E を代替しない。

## リスク

- kernel はホスト上の実ファイルを参照するため、誤った path で VM に不要なファイルを読み込ませる可能性がある。絶対パス / UTF-8 / 実ファイルの検証と start 前 fail-fast に限定し、検証順序をテストで固定する。
- masked / readonly path の空リストは保護を弱める方向の設定になる。未指定と空リストを型で区別し、意図的な指定だけが既定無効化になるようテストする。
- Apple CLI と XPC で挙動が異なる期間がある。capability gate で「未対応はエラー」を徹底し、暗黙 fallback をしない。
- Apple の version 依存（masked / readonly path は Apple container 1.2.0 以上）。README / サポート表に version 要件を記録する（0051 と整合）。
- ロールバック: option 層と fail-fast の追加に限定され、対応済みの既存経路の契約を変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] macOS 専用の `with_ssh` / `with_masked_paths` / `with_readonly_paths` / `with_kernel` を追加する

## 注記

- 参照: [src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)、[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)。
- 関連: [docs/TESTCONTAINERS.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/docs/TESTCONTAINERS.md) の Apple container 1.2.0 前提と XPC route 一覧（`containerCreate` / `getDefaultKernel`）、[docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の実機受入。
- 0004（副作用前の明示拒否）と 0019（capability gate）の方針に従う。証跡として version / OS / 実行ログ / 前後の `container list --all` を残す（0052 の CI 方針と整合）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
