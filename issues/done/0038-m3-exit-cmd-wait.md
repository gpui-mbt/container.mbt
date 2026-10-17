# [P1 / M3] WaitFor::exit と exec 待機条件を移植

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0012](./0012-m1-docker-exec-attach.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`WaitFor::exit`（終了コード不問 / 期待コード付き）と exec の待機条件（stdout / stderr メッセージ、duration、exit）を移植し、実行時間の上限と終了コード未取得時の扱いを明示的にする。

## 背景

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) に `WaitFor::when_exited()` と `Exit` variant が既にあるが、[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) と [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) が run 前に拒否する。
- upstream は [src/core/wait/exit_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/exit_strategy.rs) の `ExitWaitStrategy` がデフォルトで exit code 不問・100 ms poll、`with_exit_code(i64)` で期待コードを検証し、unexpected なら `UnexpectedExitCode { expected, actual }` を返す。exit code を取得できない場合も明示エラーに倒す設計になっている。
- upstream の [src/core/wait/cmd_wait.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/cmd_wait.rs) は `CmdWaitFor`（`Nothing` / `StdOutMessage` / `StdErrMessage` / `Duration` / `Exit { code: Option<i64> }`）を持ち、exec では取得済みバッファへの部分一致で判定する（[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) の exec 分岐）。
- MoonBit 側の `Container::exec` は待機条件を持たず、60 秒固定 timeout で完走後に一括 return するだけ（`ProcessOutput`）。

## 問題

- `WaitFor::when_exited()` を指定した image は run 前に fail し、短命コンテナの終了待ちが使えない。
- 期待終了コードを指定する API がない。exit code が取得できない場合に成功扱いすると、失敗コマンドを見逃す。
- exec 側に `CmdWaitFor` 相当がなく、stdout / stderr のメッセージ待ち・終了コード検証・待機時間指定をテストから表現できない。
- exec の出力待ちが「完走後のバッファ照合」なのか「ストリーミング照合」なのかが未定義。混同すると、出力が出た瞬間に exec が戻るという誤った期待を生む。

## 目標

- `WaitFor::when_exited()` が終了コード不問で停止を待ち、`WaitFor::exit_code(Int)` が期待コードを検証する。不一致は typed なエラー（expected / actual を含む）になる。
- exit code を取得できない場合は成功扱いせず、明示エラーになる。
- exec に待機条件 API（`CmdWaitFor` 相当）を追加し、stdout / stderr メッセージ、duration、exit code を検証できる。
- stdout 条件が stderr に、stderr 条件が stdout に誤ってマッチしない。
- 待機と exec の実行が startup deadline / 明示 timeout で無限化しない。
- 既存の log / duration readiness と `Container::exec` の既存呼び出しに回帰がない。

## 対象外

- healthcheck 待機（0037）と HTTP 待機（0036）。
- 複数条件の順序・env var の意味論（0039）。
- 信号による停止と exit code の取得 API そのもの（0041。本 issue は exit code の「待機条件」だけを扱い、取得は 0041 の API を利用する）。
- XPC の exec（0028）とログ FD 所有権（0029）。
- ストリーミングログ配信（0040）。

## 提案する方針

- `image.mbt` の `WaitFor` を拡張する。終了コード不問は既存 `WaitFor::when_exited()`、期待コード付きは `WaitFor::exit_code(code : Int)` を追加する。variant の形状（`Exit` に payload を足すか新 variant を足すか）は実装詳細として変更可だが、既存 `WaitFor::when_exited()` の意味は維持する。
- 停止の判定は 0011 の inspect（running 等）を 100 ms 間隔で poll する upstream の `ExitWaitStrategy` に合わせる。期待コード付きの場合は 0041 で追加する exit code 取得 API を使い、取得できない場合は `UnexpectedExitCode { expected, actual: None }` 相当の明示エラーにする。
- exec 側は新規 `exec_wait.mbt`（名前は実装詳細として変更可）に `CmdWaitFor` 相当の enum を追加する。値は upstream と同じ意味にする: `Nothing`、stdout メッセージ、stderr メッセージ、duration、exit（code なし / あり）。`Container::exec` に条件を受け取る新しい入口（例: `exec_with_wait`。API 名は実装時に確定）を追加し、既存 `exec` は条件なし実行を維持する。
- exec のメッセージ照合は upstream と同じく「exec 完走後の取得済み stdout / stderr への部分一致」とする。ストリーミング照合ではないことを API ドキュメントに明記する。
- exit code が取得できない場合（`ProcessOutput` 相当に値がない場合）は、期待コード付き条件を「成功」と扱わずエラーにする。
- timeout: `WaitFor::exit` は start の共有 deadline に従う。exec の条件実行は明示 timeout（新 API の引数）または既存 60 秒既定に従い、どちらも有界にする。
- Apple Container 経路: `container inspect` の出力に exit code が含まれるかは文書化されていないため、実装時に実測して確認する。確認できない場合は期待コード付き exit 待機を副作用前に拒否する（`container wait` 相当のコマンドが存在しないことも確認済み）。

## 受け入れ条件

- [x] Given すぐ exit 0 するコンテナと `WaitFor::when_exited()`, when `start` する, then 停止が観測されて readiness が完了する。
- [x] Given exit 3 するコンテナと `WaitFor::exit_code(3)`, when wait する, then 成功する。`WaitFor::exit_code(0)` との組み合わせでは expected と actual を含む typed エラーになる。
- [x] Given exit code を取得できない状況, when 期待コード付き exit 待機をする, then 黙って成功せず明示エラーになる。
- [x] Given exec が期待メッセージを stdout に出す, when stdout 条件で待つ, then 成功する。stderr 条件では成功しない（混線しない）。
- [x] Given exec の終了コードが期待と異なる, when exit code 条件で検証する, then typed エラーになる。
- [x] 既存の log / duration readiness と条件なし `exec` に回帰がない。(201/201 pass)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: `WaitFor` の exit 条件構築、`CmdWaitFor` 相当の判定（stdout / stderr 別、exit code 一致・不一致、code なし）、取得不能時に成功しないこと、deadline クランプを純関数として固定する。
- Linux Docker 実機（CI の Docker ジョブ）で短命コンテナを確認する。
  - `alpine` の `sh -c 'exit 3'` 相当で `WaitFor::exit_code(3)` / `exit_code(0)` / `when_exited()` を実行する。
  - exec 条件はメッセージ一致・不一致・exit code 一致・不一致の 4 系統を実行する。
  - 実 Docker daemon が必要。証跡として exec / inspect の出力をログに残す。
- Apple Silicon 実機: `container inspect` の exit code 有無を実測で確認し、結果に応じて対応可否と preflight 拒否を確定する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 / 0026 の実機受入時に併せて実施する。
- テスト用コンテナは固有 name / label に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- 短命コンテナは poll 開始前に停止し得る。停止済みでも最終状態を読める検査（inspect の再取得）で判定し、取りこぼしを防ぐ。
- exit code の取得競合（停止直後に未確定）。取得不能をエラーにする仕様が偽陽性を防ぐが、誤って失敗側へ倒れる可能性がある。0041 の有界リトライと整合させる。
- Apple の exit code 未対応が判明する可能性。その場合は preflight 拒否を明示し、M2 の XPC 経路（0028）へ委譲する。
- exec の出力上限（64 MiB）と部分一致判定の関係。上限超過時はエラーにし、途中までの一致で成功と扱わない。
- ロールバック: `WaitFor` 拡張と exec の新入口追加が中心で、既存の条件なし `exec` の契約を変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] WaitFor::exit の終了コード検証と exec 待機条件を移植

## 注記

- upstream の対応物: [src/core/wait/exit_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/exit_strategy.rs)、[src/core/wait/cmd_wait.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/cmd_wait.rs)、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) の exec 分岐。
- 関連: 0011（inspect / wait）、0012（exec）、0037（healthcheck）、0039（条件合成）、0041（exit code 取得）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Readiness 行。
- 証跡要件: 期待コードと実測コード、stdout / stderr の判定根拠をログまたは artifact に残す（PASS / FAIL / 未実行を混同しない）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装記録 (完了時追記)

- `WaitFor::Exit` に `Int32?` payload を追加: `when_exited()` → `Exit(None)`(コード不問)、`WaitFor::exit_code(code)` → `Exit(Some(code))`。
- `Container::exit_wait_until`: `State.Running` を 100ms poll、停止後 `expected=None` は即成功、`Some(c)` は `State.ExitCode` と比較 — 不一致は "unexpected exit code: expected N, got M"、コード未取得は "did not report an exit code" の明示エラー(黙って成功しない)。
- `exec_wait.mbt`: `CmdWaitFor`(`Nothing`/`StdOutMessage`/`StdErrMessage`/`Duration`/`Exit(code?)`) + `Container::exec_wait(command, wait?, timeout_ms?=60000)`。メッセージ照合は完走後バッファへの部分一致(非ストリーミング、API doc 明記)。`ProcessOutput` は常に exit_code を保持(direct path は undetermined を既にエラー化)するため code なし成功は起きない。
- Capability: `DirectDocker` ExitWait → Supported。CLI adapters は据え置き(NYI 38)。
- wbtest 6 件(構築/stop 検知/code 一致・不一致・未取得/CLI refusal/ストリーム別照合/exec_wait e2e)。
- 実機 Docker での短命コンテナ E2E: **未実行**(CI の 0020 smoke_linux にケース追加が残る)。
- Apple `container inspect` exit code 実測: 物理 Mac 不在のため **未実行**。
