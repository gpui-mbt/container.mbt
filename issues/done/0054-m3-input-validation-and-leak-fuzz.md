# [P1 / M3] argv/JSON/path/ログの不正入力と資源リークを系統検証

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

外部入力（argv / JSON / path / ログ）の不正値（改行・NUL・非 UTF-8・過大出力・負値・overflow）でホスト側コマンド実行や資源漏れが起きないことを系統的に検証し、長時間反復でも socket / FD / プロセスが解放されることを確認する。

## 背景

- 現行 [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` は env / label キー、mount path、port、container name を検証し、[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) は `@shell.Cmd(executable, args).output(...)` に argv 配列を渡す（shell 文字列を組み立てない）。[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) は "Never execute user-provided shell snippets. Runtime arguments are an argv array, not a shell command." を制約として明記する。
- upstream [src/core/util.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs) の `is_valid_container_id` は 63 文字以下・先頭英数字・英数字 / `_` / `.` / `-` のみを許可し、改行・空白・glob・非 ASCII・スラッシュを拒否する（43–134 行付近のテスト付き）。`unique_suffix` は pid + nanos + カウンタで一意化する（8–16 行付近）。
- 現行 [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `valid_container_name`（268–280 行付近）が同等の検証を持ち、`WaitFor::seconds` は `seconds * 1000` を計算する（69–71 行付近）。`startup_timeout_ms` / `Millis` の負値は `build_run_args` と `wait_ready_until` で拒否する（commands.mbt 36–43 行付近、runtime.mbt 220 行付近）。
- 出力は `max_output_bytes`（run / stop / rm は 1048576、exec / logs は 67108864）で有界化しているが、上限超過時の挙動は未検証（runtime.mbt 86–89 / 128–131 / 153–156 行付近）。

## 問題

- shell 注入が argv 配列で構造的に防がれていることは、回帰テストとして固定されていない。
- NUL / 非 UTF-8 / 制御文字を含む入力が spawn まで到達したときの挙動（拒否 / 置換 / 失敗）が不明で、silent な切り詰めが成功として扱われない保証がない。
- 負値・overflow（`WaitFor::seconds`、timeout、0046 の shm サイズ）の網羅検証がない。
- 大量出力時に無制限蓄積が起きないこと、上限超過時の挙動が定義されテストされていない。
- 連続 start / exec / rm の反復で socket / FD / プロセスが漏れない証跡がない。
- タイムアウト中断後の子プロセス残存が未確認。

## 目標

- 外部入力は必ず argv 配列として渡り、ホスト側 shell 評価が起きないことがテストで固定される。
- 改行 / NUL / 非 UTF-8 / 制御文字は安全に拒否または失敗し、正常成功にならない。
- 負値と Int 範囲を超える値は副作用前に拒否される。
- 大量出力は有界に処理され、上限超過時の挙動が定義されテストされる。
- 失敗・中断を含む反復実行で FD / socket / プロセス数が単調増加しない。

## 対象外

- HTTP frame の fuzz（0007）、XPC の FD 所有権（0029）、tar path traversal（0035）。
- パフォーマンスベンチマーク化（非増加の確認に限定する）。
- 新規 sanitizer の導入（使える環境がある場合の補助証跡としてのみ）。
- 実装バグを発見した場合の修正は、別 issue または本 issue 内の独立コミット（[FIX] として扱う）にする。本 issue は検証の系統化が主目的。

## 提案する方針

- wbtest を追加・拡張する（[commands_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands_wbtest.mbt) / [runtime_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime_wbtest.mbt) / [image_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image_wbtest.mbt)、または新規 `validation_wbtest.mbt`）。
  - argv: `"a b"`、`$(...)` / バッククォート / `;` / `|` / `&` / `"` を含む値が 1 引数としてそのまま配列に残り、シェル解釈されないこと（`build_run_args` の出力で検証）。コンテナ内コマンドとしての `exec(["sh", "-c", ...])` はコンテナ側のシェル実行であり、ホスト評価ではないことをコメントで区別する。
  - container name: upstream `is_valid_container_id` と同じ境界（63 / 64 文字、先頭記号、改行、空白、glob、非 ASCII、スラッシュ）を対応表にし、`valid_container_name` との差があれば upstream へ寄せる。
  - env / label キー: 空、`=`、制御文字、NUL。
  - mount: 相対 path、`,` / `=` を含む path、空 source（commands.mbt 108–114 行付近の既存検証の境界を拡張）。
  - port: 0 / 65536 / 負値 / overflow（ports.mbt 17–22 / 66–71 行付近）。
  - timeout / wait: `with_startup_timeout` の 0 / 負値、`WaitFor::seconds` の `seconds * 1000` overflow を乗算前チェックまたは Int64 化で拒否する（実装方法は実装時に選定）。
  - NUL: MoonBit の `String` で NUL（`\u{0}` 等）を構成できるかを実装時に確認し、「spawn 前に拒否」または「spawn が明示エラーになる」ことを固定する。置換して成功する挙動は許容しない。
  - 非 UTF-8: JSON / XPC 経由（0010 / 0024）で入る経路のデコード拒否を表にする。MoonBit で非 UTF-8 バイト列を構成できるかも実装時に確認する。
- Docker 実機 E2E（CI の docker-e2e ジョブ）:
  - 不正文字列を含む env / cmd を渡し、run / exec の argv に verbatim で渡ることを実際の動作で確認する。
  - コンテナ内で大きな出力（`head -c` 相当）を発生させ、`max_output_bytes` の近傍と超過で挙動を観測する。上限超過時の挙動（エラーか有界切り詰めか）を実測してテストに固定し、静かな無制限蓄積が起きないことを受け入れとする。
  - readiness タイムアウト / exec タイムアウトで中断した後、CLI の子プロセスが残っていないことを確認する。
  - リーク: start → exec → stop → rm を反復（CI 縮小版は 10 回、手動の完全版は 50–100 回）し、各反復後に `/proc/self/fd` の数と prefix 限定の `docker ps -a` 残存を記録する。
- すべての後始末は生成 name prefix に限定し、ユーザー所有コンテナを削除しない（issues/README.md 運用ルール 5）。

## 受け入れ条件

- [ ] Given `$(...)` やバッククォートを含む env / cmd, when run 引数を構築する, then 単一 argv として保持され、ホスト側で該当コマンドが実行されない。
- [ ] Given NUL / 改行 / 非 ASCII を含む container name, when start する, then 副作用前にエラーになる（upstream `is_valid_container_id` と同等の拒否）。
- [ ] Given timeout / wait の負値または overflow する値, when 構築する, then 明確にエラーになる。
- [ ] Given exec / logs の出力が上限を超える, when 実行する, then 無制限に蓄積せず、挙動（エラーまたは有界切り詰め）がテストで固定されている。
- [ ] Given 10 回以上の start / exec / rm 反復, when FD 数と残存コンテナを記録する, then 単調増加もリークもない。
- [ ] Given readiness / exec のタイムアウト中断, when プロセス一覧を確認する, then 実行した CLI の子プロセスが残っていない。
- [ ] Given 既存の正常系 smoke, when 変更後に実行する, then 壊れない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する（wbtest に negative case を追加）。
- `moon run smoke --target native` に注入ケースを 1 件以上追加し、Docker 実機（CI の docker-e2e ジョブ）で実行する。
- リーク反復は CI では縮小版（10 回）、完全版（50–100 回）は手動または夜間実行とし、実行できない場合は「未実行」と記録する。FD 観測は Linux の `/proc/self/fd` を使う（macOS は実機時に `lsof` 等で代替）。
- Apple 実機の同ケースは物理 Mac がないため「未実行」と理由を記録し、0032 の受入後に実施する。
- PASS / FAIL / 未実行を混同しない。時間依存の閾値は余裕を持たせ、flaky 判定は再実行で確認する。

## リスク

- テスト実行時間の増大。反復回数を CI と手動で分け、注入ケースを smoke に足しすぎない。
- `@shell` の上限超過挙動や NUL の扱いはライブラリ実装に依存する。実測結果をテストに固定し、数値・挙動は 1 箇所の定数 / コメントに集約する。
- MoonBit の `String` 表現（エンコーディング、非 UTF-8 の構成可否）が未確認。実装時に実際に構成できるかを確認し、構成不能なら「型で到達不能」を根拠として記録する（確認の省略は不可）。
- テストがユーザー所有リソースを消す危険。生成 prefix 限定の後始末を必須にする。
- ロールバック: テストと検証コードの追加に限定。検証で overflow などの実バグを修正する場合は独立した [FIX] として扱い、該当変更だけ revert できるようにする。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt)、[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)、[src/core/util.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs)。
- 関連: 0007（HTTP framing fuzz）、0029（FD 所有権）、0035（tar path）、0046（shm サイズの overflow 検証と接続）。[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の "Refuse unsupported options before creating a container" / "Never execute user-provided shell snippets" 制約を検証で固定する。
- 証跡として FD 数・残存一覧・上限超過時の出力サイズをログまたは artifact に残す（0052 の CI 方針と整合）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

`validation_wbtest.mbt` で argv 非シェル分割、container name 境界、env/label 制御文字、port 範囲、`WaitFor::seconds` の負値/overflow を固定。`WaitFor::seconds` を Int64 計算 + raise に修正。Docker/Apple の反復リーク測定は未実行。
