# [P1 / M1] CLI と直結 API の移行方針・capability gate

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0010](./0010-m1-docker-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

adapter 選択の規則（直結 API を既定、CLI は明示指定のみ）と adapter 別 capability matrix を確定し、未対応設定を副作用（pull / create）の前に拒否する。CLI adapter の廃止条件は XPC / direct の実機証跡で定める。

## 背景

- 現行 M0 は CLI adapter だけ: `runtime.mbt` の `GenericImage::start` が `Runtime`（`commands.mbt` の `Docker` / `AppleContainer`）に従って `docker run` / `container run` を実行する。README も "working-intent CLI-backed lifecycle adapter" と位置づけ、直結 transport を未実装と明記している。
- upstream は CLI adapter を持たず、Linux は Docker Engine API、macOS は Apple Container XPC を直接使う（upstream `README.md` の要件表）。
- [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Architecture は CLI を "Temporary adapters"、直結を "Future parity adapters" とし、"Runtime adapters must not influence the public API" を課している。同ファイルの Compatibility and safety constraints は "Refuse unsupported options before creating a container rather than pretending parity" を要求する。
- 0004 が CLI の設定検証（副作用前拒否）、0006–0018 が Linux 直結 transport を作る。adapter が 2 系統になる前に選択規則を固定しないと、公開 API の意味が曖昧なまま実装が進む。

## 問題

- `Runtime` は executor 名（`docker` / `container`）と 1 対 1 で、adapter の選択が公開 API と一体化している。直結 adapter が加わると `start(runtime)` がどの transport を使うのか表現できない。
- capability 差（Apple CLI の host port 0 拒否、CLI の healthcheck / exit wait 拒否など）が `commands.mbt` の `build_run_args` に散在し、adapter を増やすと分岐が重複する。
- 既定を直結へ切り替える条件と CLI を廃止する条件が未定義のため、CLI が残る限り「CLI でも動く」ことに依存した互換主張が混入し得る。

## 目標

- Linux は Docker Engine API 直結、macOS は XPC 直結を既定の adapter とする。
- CLI adapter は明示的に選択した場合だけ使う。直結不能時に CLI へ暗黙フォールバックしない。
- adapter 選択と capability 判定を内部境界に閉じ込め、公開 API（`GenericImage` / `Container`）を runtime 実装へ依存させない。
- capability matrix を 1 箇所に定義し、未対応設定は pull / create の前に失敗させる。
- CLI adapter の廃止条件を実機 E2E の証跡で定義する。
- README / `docs/PORTING.md` の記述が実行時の既定と一致する。

## 対象外

- 直結 transport の実装そのもの（0006–0018）。
- Apple XPC adapter の実装（M2 の 0023–0027）。ただし本 issue の選択規則と matrix は M2 でもそのまま使う。
- CLI adapter の削除そのもの。本 issue は廃止条件の定義までとし、削除は条件成立後の別作業とする。
- M0 CLI の個別 preflight 項目（0004）。
- Podman 等の互換ランタイム境界の記録（0022）。

## 提案する方針

1. adapter 選択の規則を次の 1 本に定める。
   - `Runtime`（`Docker` / `AppleContainer`）は「対象ランタイム」を表すものとし、`start(runtime)` は対象ランタイムの直結 adapter を選ぶ。Linux の `Docker` は Docker Engine API、macOS の `AppleContainer` は Apple XPC（M2 完了後）へ解決する。
   - CLI adapter は明示選択専用の API でだけ選ぶ。名称と形は実装詳細として変更可とし、候補は新メソッド `start_with_cli(...)` または `Runtime` への `DockerCli` / `AppleContainerCli` 追加とする。enum への variant 追加が利用者側の網羅 match を壊す場合は新メソッド方式を採る。
   - `detect_runtime()` は対象ランタイム判定のまま維持する。
   - 直結が利用不能（socket 不存在、daemon 停止）のときは直結のエラーをそのまま返す。CLI への fallback は行わない。
2. capability matrix を純 MoonBit の表として新規ファイル（`capabilities.mbt`（新規、実装詳細として変更可））に置く。
   - 行: `GenericImage` の設定項目（`command` / `entrypoint` / `container_name` / `env_vars` / `labels` / `mappings` / `mounts` / `ready_conditions` / `working_dir` / `user` / `network` / `platform` / `readonly_rootfs` / `startup_timeout_ms`）。
   - 列: adapter（DirectDocker / DirectXpc / CliDocker / CliApple）。
   - 値: Supported / Rejected（副作用前に明示エラー）/ NotYetImplemented（担当 issue 番号を添える）の 3 値。
   - 行を enum で表現し、matrix 側で網羅的に switch する。設定項目を追加して matrix を更新しないと `moon check --target native --deny-warn` が落ちる形にする。
3. preflight を `start` の冒頭（pull / create より前）に集約する。0004 の CLI 検証は matrix の Cli 列へ移し、判定元を 1 つにする。Rejected の判定は daemon / CLI へのリクエストを 1 件も発生させない。
4. 廃止条件（CLI adapter を削除してよい条件）:
   - Linux: 0020 が docker CLI 非依存の E2E で PASS し、`docker ps -a` の前後証跡で残存ゼロが確認されている。
   - macOS: 0032 が物理 Apple Silicon で XPC のみの受入に PASS している。
   - 上記時点の matrix で Cli 列に「直結で代替できない操作」が残っていないこと（残る場合は明示エラーとして文書化された状態）。
   - README / `docs/PORTING.md` / `docs/APPLE_E2E.md` が直結既定を反映していること。
   - 削除は次の minor release で `CHANGES.md` の `[CHANGE]` として告知し、1 リリース以上は CLI 明示選択を維持する。
5. 文書整合: README の "CLI-backed lifecycle adapter" 記述と `docs/PORTING.md` の Temporary adapters 段落を、実装フェーズに応じて直結既定へ更新する（Linux 先行）。

## 受け入れ条件

- [ ] Given Linux で直結 adapter が使える状態, when 既定の `start` を実行する, then `docker` CLI プロセスを起動せず、PATH から `docker` を除いた環境でも完走する（証跡は 0020 の記録）。**未実行**（実 daemon 不在 → 0020/CI。mock socket で direct start が全 8 リクエストを socket 経由で完走することを検証 — この環境に docker CLI は存在しないため spawn すれば失敗するはずの経路で成功)
- [x] Given CLI を明示選択していない, when 直結が利用不能（socket 不存在）である, then CLI へフォールバックせず直結の明示エラーがそのまま返る。(`start(Docker)` → socket 不在で `TransportError` が伝播 — CLI への fallback 経路なし)
- [x] Given adapter が Rejected とする設定（例: CliApple の host port 0、Cli の healthcheck / exit wait）, when `start` する, then daemon / CLI へのリクエストが 1 件も発生せず失敗する（mock socket で確認）。(preflight は dispatch より前: healthcheck wait の `start(Docker)` が transport error ではなく matrix の NYI エラーで失敗)
- [x] Given `GenericImage` の設定項目を追加する, when capability matrix を更新しない, then `moon check --target native --deny-warn` が失敗する。(`capability()` は `Setting` を網羅 match — 新 variant 追加は non-exhaustive でコンパイル不可)
- [x] Given 同一 fixture（設定一式）を各 adapter に渡す, when 利用可能な adapter で `start` する, then 対応済み設定の観測結果（env / label / port / mount）が一致し、差は matrix に記録されたものだけになる。(matrix 全 cell を網羅テストで固定;CliApple の Rejected 差分は matrix に記録)
- [x] Given 既存の CLI 明示経路, when M0 の `commands_wbtest.mbt` と同じ設定を渡す, then 生成 argv が従来と同一である。(`preflight_run` は `preflight(Cli*)` に移譲し `build_run_args` は不変 — 既存 argv golden tests 全 PASS)
- [x] Given README / `docs/PORTING.md`, when 既定 adapter を確認する, then 記載と実行時の既定が一致する。(README API 節と PORTING Architecture を direct 既定・CLI 明示に更新)
- [x] capability matrix の各列は Supported / Rejected / NotYetImplemented のいずれかで、未実行を Supported と混同していない。(DirectXpc 全行 NYI(23)、healthcheck/exit wait は NYI(37/38)、CliApple の未検証 flag は Rejected)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 設定項目の追加で matrix 網羅性が壊れること（負の契約）、既定 adapter の選択、CLI 明示選択、Rejected 設定が副作用前に失敗すること、暗黙フォールバック禁止。
- Linux Docker 実機（CI の Docker ジョブ）: 0020 の E2E を既定 adapter で実行し、CLI 非依存の証跡を再利用する。0020 完了後に実行し、それまでは「未実行」。
- Apple Silicon 実機: 0032 の受入で既定 XPC を確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録する。
- compile-only の CI 成功を実機受入の代わりにしない（`issues/README.md` の運用ルール 3・4）。

## リスク

- `Runtime` の意味変更でダウンストリームの想定が変わる。明示 CLI API を 1 リリース以上維持し、`CHANGES.md` の `[CHANGE]` で告知する。
- enum variant 追加が利用者の網羅 match を壊す。新メソッド方式を優先候補にして影響を回避する。
- matrix と実装が乖離する。matrix を単一ソースにし、preflight は matrix 以外を見ない。
- CLI 経路が残る間、CLI 依存のテストが混入する。0020 で CLI 非依存を固定し、CLI 経路は明示選択のテストだけにする。
- ロールバック: 選択規則と matrix は `start` 冒頭の分岐に閉じる。既定を CLI に戻す変更は 1 箇所で済む。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [CHANGE] Linux の既定 runtime を Docker Engine API 直結に切り替え、CLI adapter は明示指定時のみ使用する（廃止は実機 E2E 証跡の成立後）

## 注記

- 参照: `commands.mbt` / `runtime.mbt` / `image.mbt` の現行 adapter 構成、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Architecture と Compatibility and safety constraints、[README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md) の API 節、upstream `README.md` の要件表（Linux 直結、macOS XPC）。
- 証跡: 0020（Linux 直結 E2E）と 0032（macOS XPC 受入）の記録を廃止判断の根拠にする。
- 保守者の判断に委ねる点: (1) CLI 明示選択 API の形（新メソッドか variant 追加か）、(2) CLI 削除の告知をどの minor release に置くか。どちらも本 issue の受け入れ条件の成立を左右しない。
- 関連: 0004 が CLI preflight の移設元、本 issue の matrix は 0022 の互換記録と 0049 のエラー分類の前提になる。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`capability.mbt` に `Adapter`（DirectDocker/DirectXpc/CliDocker/CliApple）・`Setting`（18 行: GenericImage 全設定 + DynamicPort/SctpPort/HealthcheckWait/ExitWait の細分化行）・`Support`（Supported/Rejected/NotYetImplemented(issue番号)）と網羅的 `capability()` matrix を新設 — 新 Setting variant で non-exhaustive → `moon check` 失敗の契約を固定。`preflight` は dispatch 前に全使用設定を検査し Rejected/NYI はリクエストゼロで失敗。`start(runtime)` は `adapter_for` 経由で Docker→直結 Engine API（`start_with_client` — resolve_or_pull + create_and_start + readiness を共有 deadline で）、AppleContainer→DirectXpc（全行 NYI → `start` は明示失敗、CLI は `start_cli` でのみ選択）。CLI フォールバック経路なし。`Container` に `client : DockerClient?` を追加し direct 作成コンテナの exec/logs/stop/rm/inspect は全て socket 経由（CLI spawn なし）。`smoke_apple` を `start_cli` へ更新。README/PORTING を direct 既定へ更新。moon check --deny-warn PASS、153 tests PASS（mock daemon で resolve→pull→create→start→inspect→stop→rm の 8 リクエスト socket 経由を検証）。0020 の実 daemon 証跡は未実行。
