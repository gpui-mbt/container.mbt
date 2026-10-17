# [P0 / M1] Linux daemon 直結の起動から削除までの E2E

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0010](./0010-m1-docker-create-start.md), [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0012](./0012-m1-docker-exec-attach.md), [0013](./0013-m1-docker-log-stream.md), [0014](./0014-m1-dynamic-published-ports.md), [0018](./0018-m1-engine-deadline-cancel.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API 直結（docker CLI 非依存）で pull→create→start→wait→exec→logs→inspect→stop→rm を完走する Linux 実機 E2E を追加し、残存ゼロ・失敗時 cleanup・操作ごとの証跡を固定する。

## 背景

- 現行 `smoke/main.mbt` は `@container.Docker`（CLI adapter）で lifecycle を実行し、検証用 probe も `@shell.Cmd("docker", ["inspect", ...])` を使う。[.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml) の Linux ジョブは `docker pull` と `moon run smoke --target native` までで、直結 transport は一度も実行されない。
- 0006–0014 と 0018 が Unix socket transport、HTTP framing、pull、create/start、inspect/stop/rm/wait、exec、logs、動的 port、deadline を提供する。個別の単体テストが揃っても、結合した実機受入がなければ `docs/PORTING.md` の M1 完了条件を満たさない。
- upstream Linux 経路は Docker Engine API 直結で docker CLI を前提としない（[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)）。CLI smoke の成功は直結 transport 完了の証明にならない。

## 問題

- 直結実装の結合・期限・cleanup が実機で検証されていない。
- 既存 smoke は成功経路と readiness 失敗ロールバックを CLI 経由でしか見ておらず、inspect 値（running 状態、published port）や rm 後の not found を直結 API で確認していない。
- 「docker CLI がなくても動く」という M1 の中核主張を裏付ける実行が存在しない。

## 目標

- docker CLI が PATH にない状態で、pull→create→start→wait→exec→logs→inspect→stop→rm が完走する。
- 各操作の証跡（step 名、container ID、結果要約、所要時間）が実行ログに残る。
- テスト由来コンテナだけを固有 prefix で識別し、終了後に残存ゼロ。
- 失敗経路（readiness 失敗、exec 非ゼロ終了）でも cleanup が走り、残存しない。
- 事前に存在する無関係なコンテナを削除しない。

## 対象外

- CLI adapter の比較と移行方針（0019）。
- 動的 host port の host TCP 到達検証（0014 の範囲。本 issue は inspect が返す値の一致まで）。
- exec 多重化・attach・長大ログの詳細（0012 / 0013 の単体範囲を結合で最小確認するに留める）。
- プロセスクラッシュ後の残存回収（0021）。
- Podman / Docker rootless（0022）。
- Apple Silicon 実機の受入（M2 の 0032）。

## 提案する方針

- 新規 `smoke_linux/main.mbt`（新規、実装詳細として変更可）を追加し、CLI を使わず直結 API のみで次を順に実行する。
  1. pull（alpine:3.20。既存 smoke と同じ固定タグ）
  2. create（固有 name + 所有 label、固定 host port マッピング 1 件）
  3. start
  4. wait（startup deadline 内の起動完了条件を 1 つ。既存 smoke と同じ log message 系）
  5. exec（stdout / stderr / exit code の一致確認）
  6. logs（bounded 取得）
  7. inspect（running 状態、published port が指定値と一致）
  8. stop（grace 付き）
  9. rm
  10. inspect（not found の確認）
- 固有 prefix: name を `container-mbt-linux-e2e-<run-id>` とし、label（`container-mbt.owned=<run-id>`。0001 の label 規則を共有し二重定義しない）を付ける。cleanup もこの prefix / label に限定する。
- cleanup: `errdefer` で `rm --force` 相当を best-effort 実行し、成立確認は直結 inspect / list で行う。cleanup の失敗で元の run エラーを上書きしない（0001 と同じ方針）。
- 失敗注入: readiness が期限内に成立しない fixture（現れない message を待つ + 短い startup timeout）を 1 件含め、エラー後にコンテナが残らないことを確認する。
- PATH 検証: ライブラリ実行 step の `PATH` から docker バイナリのディレクトリを除いて実行する（`moon` と標準コマンドだけが解決できる最小 PATH。具体的な構成は CI YAML の実装で確定する）。前後の `docker ps -a` は PATH を限定しない別 step で取得し、前後差分と実行ログを artifact に残す。
- CI: 既存の ubuntu-24.04 job に step を追加する（または専用 job）。0052 の platform matrix と表現を揃え、compile-only と実機実行を混同しない。
- 証跡: 各 step の標準出力、`docker ps -a` の前後、異常系のエラー本文。`issues/README.md` の運用ルール 2・5 に従う。

## 受け入れ条件

- [ ] Given PATH から docker CLI を除いた Linux（docker daemon 稼働）, when `moon run smoke_linux --target native`, then 列挙した手順がすべて完走し exit code 0。**未実行**（ローカルに daemon なし。CI step `Linux direct-API E2E (no docker CLI on PATH)` が `env -i PATH=/container-mbt-empty` で `_build/.../smoke_linux.exe` を実行 → 次回 CI 実行で採証）
- [ ] Given 上記実行, when 完了後の `docker ps -a`, then prefix / label 一致のコンテナが 0 件。**未実行**（CI step が `docker ps -a --format '{{.Names}}' | grep '^container-mbt'` の残存ゼロを assert）
- [ ] Given readiness 失敗 fixture, when start が失敗する, then エラーが返り、その run が作成したコンテナは残っていない。**未実行**（`smoke_linux` の `never-printed` fixture が inspect 404 を assert；mock socket では direct start の rollback errdefer を単体テスト済）
- [ ] Given 事前に別プロセスが作成した無関係なコンテナ, when smoke を実行する, then そのコンテナは実行前後で存在したまま。**未実行**（CI が `container-mbt-e2e-foreign` を事前起動し、後続 inspect で存続を assert）
- [ ] Given exec の非ゼロ終了, when 呼出が戻る, then exit code と stderr が記録され、cleanup が走る。**未実行**（`smoke_linux` の `exec-nonzero` step が exit=7/stderr を記録；errdefer が rm -f 相当を実行）
- [ ] Given 実行ログ, when 証跡を確認する, then step ごとの操作種別・対象 ID・結果要約が残り、直結 socket 経由であることが分かる。**未実行**（`step()` が `[e2e:N] name: detail (ms)` を出力し `/tmp/e2e-run.log` artifact 化；binary は PATH 不在で CLI spawn 不能）
- [ ] Given 既存の CLI smoke（`smoke/`）, when 本変更を追加する, then 既存 CI step は従来どおり PASS する。**未実行**（smoke を `start_cli` へ明示切替済 — 0019 で `start` は direct 既定のため。CI step 自体は不変）

## テスト計画

- `moon check --target native --deny-warn`、`moon test --target native`、`moon build --target native` を実行し、PASS / FAIL / 未実行を記録する。
- CI（ubuntu-24.04 + Docker daemon）: `docker info` で daemon を確認後に新 smoke step を実行し、前後で `docker ps -a` を取得する。実装前は「未実行」。
- Apple Silicon 実機: 対象外（M0 CLI は 0002、XPC 受入は 0032）。本 issue の記録には含めない。
- docker daemon が使えない環境では「未実行」と明記し、CLI smoke や compile-only で代替しない。

## リスク

- readiness 依存で CI が flaky になる。既存 smoke と同じく短い期限と決定的条件にし、sleep の積み上げで隠さない。
- PATH 制限が不完全で docker CLI 経由の偽 PASS になる。実行ログに socket 接続先を出し、CLI プロセス不出現を確認する。
- cleanup 漏れでランナーが汚れる。prefix 限定削除 + inspect 検証を行い、漏れた場合は 0021 の回収が次回実行で拾えることを確認する。
- 直結実装の未発見バグがここで初めて露出する。失敗時は該当 transport issue（0006–0018）へ切り分けて戻す。
- ロールバック: 追加は新パッケージと CI step のみ。step を外せば公開 API の挙動は変わらない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [smoke/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt)、[.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml)、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Acceptance milestones M1。
- 証跡要件: `docker ps -a` の前後と各 step のログを artifact に残す（0052 の CI 方針と整合。`issues/README.md` 運用ルール 2）。
- 本 issue の PASS は 0019 の Linux 廃止条件と 0050 の conformance 基盤の前提になる。0021 は本 smoke の fixture をクラッシュ注入へ拡張する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`smoke_linux/main.mbt` 新設 — `start(Docker)` 直結経路で preflight→pull/create/start/wait→exec（成功＋非ゼロ）→logs→inspect(running/published port)→stop→rm→inspect(404) を step 記録付きで実行し、readiness 失敗 fixture の残存ゼロも assert。`start_with_client` が `RunAttempt` を介して生成名 `?name=` と所有 label `container-mbt.owned=<run-id>` を create に注入するよう修正（CLI 経路との同一契約 — 0019 の残課題）。既存 `smoke/` は `start_cli` に明示切替。CI に PATH 除去実行 step＋証跡 artifact＋foreign container 存続 assert を追加。`moon check --deny-warn` PASS、153 tests PASS、`moon build` で `smoke_linux.exe` 生成確認。実 daemon 実行は本環境不可のため全受け入れ条件は未実行 — CI 初回実行で採証。
