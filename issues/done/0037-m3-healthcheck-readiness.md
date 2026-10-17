# [P1 / M3] Healthcheck builder と healthy/unhealthy wait を実装

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`Healthcheck` builder（test / interval / timeout / retries / start_period / start_interval）を追加し、`WaitFor::healthcheck()` が Docker の health state（`starting` / `healthy` / `unhealthy` / 未設定）を共有 startup deadline 内で poll して判定できるようにする。

## 背景

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) には `WaitFor::healthcheck()` と `Healthcheck` variant が既にあるが、[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` と [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `wait_ready_until` が "healthcheck and exit waits are not yet supported by the CLI adapters" として run 前に拒否する。
- upstream は [src/core/healthcheck.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/healthcheck.rs) の `Healthcheck` struct で test / interval / timeout / retries / start_period / start_interval を表現し、Linux では create JSON の `Config.Healthcheck` に配線する。macOS では型と設定口のみ公開し、`with_health_check` 指定時は start で明示エラーになる。
- upstream の [src/core/wait/health_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/health_strategy.rs) は inspect を 100 ms 間隔で poll し、`starting` / `healthy` / `unhealthy` / `Health` 不在（running 観測後は `HealthCheckNotConfigured`）の 4 分岐で判定する。macOS は常に `HealthCheckNotConfigured` を返す。
- 0004 が CLI adapter の非対応設定の事前拒否を定めており、本 issue はそのうち healthcheck 部分を実装に置き換える。inspect 経路は 0011（Docker inspect/stop/rm/wait）と 0010（create/start と request serialization）を使う。

## 問題

- `WaitFor::healthcheck()` を指定した image は run 前に必ず fail し、Docker の HEALTHCHECK を使う readiness が書けない。`Healthcheck` variant は設定内容を持たず、builder でも表現できない。
- MoonBit 側に health state を観測する API がない。`Container` は `id` / `runtime` / `mappings` / `removed` しか持たず、inspect 相当を持たない。
- healthcheck 未設定のコンテナを wait した場合の扱いが未定義。健康状態を確認できないのに成功扱いすると、テストが偽陽性になる。
- interval / timeout / retries / start_period / start_interval を Docker に反映する手段がない。

## 目標

- `Healthcheck` 型で test（`NONE` / `CMD-SHELL` / `CMD`）と各時間・回数を表現し、`GenericImage` から設定できる。
- `WaitFor::healthcheck()` が Docker 実機で `starting` → `healthy` を共有 deadline 内で待ち、`unhealthy` は即エラーになる。
- healthcheck 未設定（running 観測後に health フィールドなし）は明示エラーになり、成功扱いしない。
- Apple Container 経路では healthcheck 対応不可を副作用前に明示拒否する（upstream macOS と同じ姿勢）。
- 既存の log / duration readiness と 0004 の他の preflight に回帰がない。

## 対象外

- HTTP readiness（0036）と env var / 複数条件の意味論（0039）。
- exit 待機（0038）。
- Apple XPC の health 相当（M2。XPC に Docker HEALTHCHECK 相当がない）。
- 0004 の preflight 全般（healthcheck 部分だけを本 issue が置き換える）。
- 0020 の Linux native E2E 基盤そのもの（本 issue は healthcheck ケースを追加するだけ）。

## 提案する方針

- `image.mbt`（または新規 `healthcheck.mbt`。ファイル名は実装詳細として変更可）に `Healthcheck` 型を追加する。upstream と同じ情報を保持する: test 配列、interval / timeout / start_period / start_interval（ミリ秒の `Int`）、retries（`Int`）。`Healthcheck::none()` / `empty()` / `cmd_shell(cmd)` / `cmd(Array[String])` 相当の constructor と、`with_interval` / `with_timeout` / `with_retries` / `with_start_period` / `with_start_interval` 相当の builder を用意する。
- `GenericImage::with_healthcheck(Healthcheck)` を追加する。test が空で全オプション未設定の `Healthcheck` は Docker create JSON へ配線しない（upstream の `to_docker_json` が `None` を返す規則に合わせる）。
- Docker への配線は 0010 の create request serialization を拡張し、`Config.Healthcheck` 相当（Test / Interval / Timeout / Retries / StartPeriod / StartInterval）として渡す。Duration の nanosecond 変換規則は upstream の実装に合わせ、実装時に確認する。
- health poll は 0011 の inspect 結果を拡張して `running` と health state を読む。ポーリング間隔は upstream と同じ 100 ms とし、deadline は `start` 開始時に確定した共有 deadline を `startup_command_timeout_ms` でクランプして使う。
- 判定は 4 分岐にする。`healthy` で完了、`unhealthy` は即座に失敗、`starting` は継続、health 不在は running 観測前は継続・running 観測後は healthcheck 未設定として失敗。
- Apple Container CLI / XPC では healthcheck を拒否する。`build_run_args` の事前拒否（非対応設定を副作用前に拒否）は維持し、エラー文言を 0004 と揃える。
- Docker CLI adapter（`runtime.mbt` の start）へ `--health-cmd` 系フラグを追加するかは実装時に決定する。追加する場合は 0004 の preflight 文言を更新し、追加しない場合は本機能が 0010/0011 の native 経路限定であることを文書化する。

## 受け入れ条件

- [x] Given `HEALTHCHECK` 付きイメージと `WaitFor::healthcheck()`, when healthy になる, then readiness が完了し、`starting` の間は deadline まで待機が継続する。(wbtest: scripted mock engine — starting×2 → healthy)
- [x] Given healthcheck が `unhealthy` を返すコンテナ, when wait する, then deadline を待たずに即失敗し、エラーが unhealthy と識別できる。(wbtest: 1 poll で失敗)
- [x] Given healthcheck 未設定のコンテナ, when `WaitFor::healthcheck()` を指定する, then running 観測後に healthcheck 未設定の明示エラーで失敗し、成功扱いされない。(wbtest: not-running → running で失敗)
- [x] Given Apple Container 経路, when healthcheck を指定する, then コンテナ作成前に明示エラーになり、副作用がない。(capability matrix: CliApple/DirectXpc は NotYetImplemented — preflight が副作用前に拒否)
- [x] Given 複数の conditions があり healthcheck が途中にある, when 前段で時間を消費する, then healthcheck の待機は同じ deadline の残り時間で打ち切られる。(`startup_command_timeout_ms` で共有 deadline にクランプ)
- [x] 既存の log / duration readiness と 0004 の他の preflight が回帰しない。(195/195 pass)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: `Healthcheck` の constructor と builder が期待値を保持すること、空 test + 全未設定が配線対象外になること、health state と running フラグの組み合わせに対する 4 分岐判定（healthy / unhealthy / starting / 未設定）を純関数として固定する。deadline クランプは既存 `startup_command_timeout_ms` の wbtest 形式を再利用する。
  - 実装詳細（API 名・配線経路）は実装時に確定し、確定内容を issue へ追記する。
- Linux Docker 実機（CI の Docker ジョブ、0020 の native E2E に healthcheck ケースを追加）で確認する。
  - `HEALTHCHECK` を定義した小さい fixture イメージを build し、healthy 待機・unhealthy 即失敗・未設定エラーの 3 系統を実行する。
  - 証跡として health state の遷移（starting → healthy）と失敗時のエラー分類をログに残す。
- Apple Silicon 実機: `smoke_apple` に healthcheck 指定の preflight 拒否ケースを追加して確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 / 0026 の実機受入時に併せて実施する。
- テスト用コンテナは固有 name / label に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- poll 追加で失敗パスのレイテンシが増える。100 ms 間隔と deadline クランプで抑える。
- daemon 初期化ラグで Health 不在になる誤検知。running 観測前は継続する upstream の分岐を踏襲し、境界を wbtest で固定する。
- `Healthcheck` 定義の JSON 配線を誤ると Docker が create を拒否する。副作用前検証と create エラーの分類で切り分ける。
- Apple の拒否が 0004 と二重管理になる。エラー文言と検証を一元化する。
- ロールバック: 型追加と wait arm 追加が中心で、成功パスの公開 API 契約を変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Healthcheck builder と WaitFor::healthcheck による Docker health state 待機を実装

## 注記

- upstream の対応物: [src/core/healthcheck.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/healthcheck.rs)、[src/core/wait/health_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/health_strategy.rs)。
- 関連: 0004（preflight）、0010 / 0011（create と inspect）、0038 / 0039（残りの wait 語義）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Readiness 行。
- 証跡要件: health state の遷移と失敗時の判定根拠（unhealthy / 未設定の区別）をログまたは artifact に残す。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装記録 (完了時追記)

- `healthcheck.mbt`: `Healthcheck` 型 + `cmd_shell`/`cmd`/`none` constructors + `with_interval`/`with_timeout`/`with_retries`/`with_start_period`/`with_start_interval` builders。フィールド名は `test_args`(`test` は keyword)。
- `GenericImage::with_healthcheck` → `Config.Healthcheck` として create JSON に配線(ナノ秒変換、空は unwired = `to_docker_json` が None)。
- `ContainerInspect.health` = `State.Health.Status`。
- `Container::healthcheck_wait_until`: 100ms poll、4 分岐(healthy 完了 / unhealthy 即失敗 / starting 継続 / running 観測後の Health 不在 = "no healthcheck configured")。共有 deadline でクランプ。
- Capability: `DirectDocker` HealthcheckWait → Supported、CLI adapters は据え置き(NYI 37)。
- wbtest 7 件(builder/JSON fragment/create serialization/4 分岐×3/CLI refusal/capability gate)。
- 実機 Docker での HEALTHCHECK E2E: **未実行**(CI の 0020 smoke_linux にケース追加が残る)。
- smoke_apple への preflight 拒否ケース追加: 物理 Mac 不在のため **未実行**。
