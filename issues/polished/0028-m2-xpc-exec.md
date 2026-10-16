# [P1 / M2] Apple XPC exec と stdout/stderr/exit code を取得

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC の `containerCreateProcess` / `containerStartProcess` / `containerWait` を使い、CLI バイナリに依存せず exec の stdout / stderr と exit code を同一セッションで同期して取得する。出力は有界に蓄積し、失敗後も FD を残さない。

## 背景

- 現行 MoonBit の `Container::exec`（[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)）は `docker exec` / `container exec` の CLI を spawn し、`@shell.Cmd(...).output(max_output_bytes=67108864)` で exit code / stdout / stderr を `ProcessOutput` にまとめる。Apple 経路は `container` CLI バイナリへの依存が残る。
- upstream は `XpcClient::exec`（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）で stdout / stderr 用の pipe を作り、`processConfig` と write FD を `containerCreateProcess` へ送る。write FD は dup 後に閉じる（閉じないと EOF が来ない）。読み取りは `containerWait` と並行に走らせる（直列化すると 64 KiB の pipe buffer が埋まって deadlock する）。
- 公開型は `ExecResult`（[src/core/containers/async_container/exec.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container/exec.rs)）で、`exit_code` / `stdout` / `stderr` を持つ。
- upstream の exec 用 `ProcCfg` は `workingDirectory` を `/` に固定し、`user` を root（uid 0, gid 0）に固定する。環境変数はコンテナ作成時 env を基底に exec 指定分で上書きする（[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) の `exec`）。
- `processIdentifier` はタイムスタンプだけでは並行 exec で衝突するため、プロセス内カウンタを組み合わせた `exec-<unique_suffix>` を使う。
- reader は EOF が来ない異常系に備えて `EXEC_READER_JOIN_TIMEOUT`（5 秒）で打ち切り、キャンセルフラグで FD を閉じる。打ち切り時は読み切れた分の出力と exit code を破棄する。

## 問題

- XPC native の exec が未実装で、0024 の型契約と 0026 の create/start だけではコマンド実行・出力回収・終了コード同期の経路がない。
- pipe の close 漏れ、wait と read の直列化による deadlock、`containerWait` 失敗時の reader リークという、upstream が明示的に対策している異常系が MoonBit 側では未定義。
- 出力蓄積の上限が未定で、無制限に保持すると OOM になり得る。

## 目標

- CLI バイナリを起動せず、XPC 経路のみで exec を完了する。
- stdout / stderr が混線せず、exit code が出力と同一セッションで同期して返る。
- 出力蓄積を 64 MiB に制限し、超過時は切り詰めずエラーにする。
- `containerWait` 失敗・reader 打ち切り時も FD を残さず、次の exec が成功する。
- 並行 exec で `processIdentifier` が衝突しない。

## 対象外

- Docker Engine の exec 多重化（0012）とログストリーム（0013）。
- exec 後の ready condition 待機と exit 待機（0038、0039）。
- LogConsumer への exec 出力の配信（0040）。
- 対話的 terminal / stdin。upstream の exec も `terminal: false` 固定であり、必要になった時点で別 issue とする。

## 提案する方針

- 0024 が定める XPC 配置に `exec` を追加する（例: `xpc_client.mbt`（新規、実装詳細として変更可））。公開 API は既存の `Container::exec` / `ProcessOutput` の契約（exit_code / stdout / stderr）を維持する。
- pipe は 0023 の FFI 境界で作成し、read 側を所有、write 側は送信後に閉じる。両端に FD_CLOEXEC 相当を付け、全エラーパスで defer により close する。
- `processConfig` は upstream と同じく `executable` / `arguments` / `environment`（`KEY=VALUE` 配列、コンテナ env を基底に exec 分で上書き）/ `workingDirectory`（`/` 固定）/ `terminal: false` / `user`（root 固定）を送る。`with_working_dir` / `with_user` が init 専用であることを docs へ明記する。
- 送信順: `containerCreateProcess`（stdout / stderr FD を添付）→ write FD close → `containerStartProcess` → stdout / stderr reader を `containerWait` と並行に開始 → `containerWait` 成功後に reader を join（上限 5 秒相当）→ `exitCode` を取得。
- `containerWait` 失敗時は cancel フラグで reader を打ち切り、部分出力と exit code を破棄してエラーを返す。
- 出力上限は 64 MiB（`67108864`。現行 CLI adapter の `max_output_bytes` と同値）とし、超過時はエラーにする。upstream の XPC exec 自体には蓄積上限がないため、MoonBit 側の bounded output 方針として明示する。
- 事前検証: コマンドが空なら XPC 送信前にエラーにする（upstream の `exec requires at least one argument` と同趣旨）。

## 受け入れ条件

- [ ] Given XPC で起動済みのコンテナ, when `exec(["sh", "-c", "printf out; printf err 1>&2; exit 3"])` する, then stdout が `out`、stderr が `err`、exit code が 3 で返る。
- [ ] Given 数 MB の連続出力, when exec する, then deadlock せず全出力を受信する（wait と並行 read）。
- [ ] Given 64 MiB を超える出力, when exec する, then 切り詰めずエラーになり、部分データを成功として返さない。
- [ ] Given `containerWait` が失敗する, when exec がエラーを返す, then reader が停止して FD が閉じ、操作前後でプロセスの FD 数が増えていない。
- [ ] Given 前回の exec が失敗した, when 同じコンテナで再度 exec する, then 成功する。
- [ ] Given 並行に 2 つの exec を実行する, when `processIdentifier` を生成する, then 重複しない。
- [ ] 既存 CLI adapter の `Container::exec` と `ProcessOutput` の公開契約を壊さない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: 出力上限の境界判定、打ち切り時に部分出力を返さないこと、`processIdentifier` 生成の一意性、空コマンドの事前拒否。XPC 通信そのものは実機なしに検証できない。
- Apple Silicon 実機（macOS 26+。CI に物理 Mac は存在しない）: alpine で正常終了・非ゼロ終了・stdout/stderr 同時出力・64 MiB 近傍と超過・`containerWait` 故障注入（不在 `processIdentifier` 等）・失敗後の再 exec・FD 数（`/dev/fd` 等で前後比較）を実行する。実行できるまで「未実行」と記録し、CI compile-only で代用しない。本実機確認は 0032 の受入に含める。
- FD 数と exec の実行ログを証跡として保存する（0052 の「実機実行と compile-only を区別する」方針と整合）。

## リスク

- pipe の close 漏れによる FD リーク: 全経路 defer close と FD_CLOEXEC で対策する。
- wait と read の直列化による deadlock: 並行 reader を仕様として必須にする。
- 64 MiB 上限で大きな出力を取得できない: 上限値と切り詰めない挙動を docs に明記する。
- `working_dir` / `user` を exec へ反映できない: init 専用であることを docs に明記し、利用者の誤解を防ぐ。
- ロールバック: 新規 XPC モジュールに閉じ、CLI adapter の経路を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Apple Container XPC の exec を実装し、stdout/stderr と終了コードを有界に取得する

## 注記

- 主な参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（`exec` と `EXEC_READER_JOIN_TIMEOUT`）、[src/core/containers/async_container/exec.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container/exec.rs)（`ExecResult`）。
- 証跡: 実行ログ、exit code、FD 数の前後比較。0032 の受入試験でまとめて記録する。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。Docker 側の exec は 0012 が担当し、本 issue は XPC 専用。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
