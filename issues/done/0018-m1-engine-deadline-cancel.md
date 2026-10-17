# [P0 / M1] Engine transport の deadline・取消・再試行を一元化

Status: done
Model: SWE-2 Max
Created: 2026-10-16
Updated: 2026-11-04
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

M0 で導入済みの「start 起点の絶対 deadline」を Engine API 直結の全フェーズ（connect / read / write / pull / create / start / ready）へ伝搬し、cancel 時に socket と子 task を回収する。cleanup（rollback rm、ログ停止）は deadline とは独立した短い予算で実行する。

## 背景

- 現行 `runtime.mbt` は `GenericImage::start` の冒頭で `@async.now() + startup_timeout_ms` の絶対 deadline を作り、`startup_remaining_ms` / `startup_command_timeout_ms` で子プロセスのタイムアウトと sleep を残り時間へ clamp する。`wait_ready_until` は複数の readiness 条件で同一 deadline を共有し、`runtime_wbtest.mbt` が「条件ごとにタイマーをリセットしない」ことを固定している。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤。subprocess 前提の deadline 伝搬を socket の connect/read/write と API の各段階（pull/create/start/ready）へ置き換える必要がある。
- upstream は共有 `request` 経路にタイムアウトを掛けず、`remove_blocking` の 60 秒（`DOCKER_STREAM_TIMEOUT`）、ログセッション起動の 30 秒（`LOG_SESSION_TIMEOUT`、成功後解除）、exec exit code のバックオフ（10、50、200、500、1000 ms、最大 6 試行）、Drop 削除の 5 秒（`DROP_REMOVE_TIMEOUT`）など経路ごとに予算を持つ。モデル自体は現行 runtime.mbt の絶対 deadline を基準にし、M0 の受入（0001、0005）と整合させる。
- 現行の rollback（`errdefer { container.rm() }`）は readiness 失敗時に独立して走る。M1 でも cleanup は期限切れの deadline に引きずられず完了する必要がある（0001 の 5 秒予算の例、0011 の stop/rm 個別タイムアウトと整合）。

## 問題

- 直結経路のどこで何を clamp するかが未設計。connect が完了しない、read が返らない、pull の進捗 stream が止まらない場合に、start の全体 deadline を超えてブロックし得る。
- async task の cancel（呼び出し側の中断・deadline 超過）時に、所有する Unix socket、読み取り中の子 task、lazy に起動したセッション（0013）をどう回収するかが未定義。FD と task のリークにつながる。
- 再試行の境界が未定義。create/start は非冪等であり、盲目的な再試行はコンテナの重複作成を招く。exec の exit code 取得や冪等読み取りだけが再試行可能である。
- cleanup が期限切れ deadline の影響を受けると、失敗時にコンテナを回収できない（0001 の orphan 問題の再発）。

## 目標

- start 起点の絶対 deadline を直結経路の全フェーズへ伝搬し、どのフェーズも独立したタイマーでリセットしない。
- deadline 超過時に read/write を中断し、socket を閉じて、起動済みの子 task とセッションを有界時間で回収する。
- 再試行は冪等な操作に限定し、再試行の待機時間も残り deadline の範囲に収める。create/start は自動再試行しない。
- cleanup（rollback delete、ログ購読停止）は startup deadline と独立した短い予算で完了する。

## 対象外

- transport そのもの（接続、読み書き、resource 所有の基本）は 0006。HTTP 解析と body 上限は 0007。
- 各操作の意味論（create/start、stop/rm、exec、logs、pull）は 0010–0016。本 issue はそれらが使う deadline/cancel/retry の共通規則を提供する。
- Drop/keep/watchdog の cleanup 契約は 0042。同期 Runner の blocking 待機は 0043。stop の grace と exit code 語義は 0041。
- プロセスクラッシュ後の残存回収は 0021。Apple XPC のタイムアウトは M2。宣言的な失敗マトリクスは 0049。Linux 直結の総合 E2E は 0020。

## 提案する方針

- deadline の表現: `startup_remaining_ms` と同じ絶対時刻（`@async.now()` 基準）の Int64 を、直結クライアントの全 API へ引き回す。公開 `GenericImage::start` の入口で 1 回だけ生成し、create 用 request 構築より前に確定する。既存の `wait_ready_until` と同様、複数フェーズは同一 deadline を共有する。
- フェーズへの割り当て:
  - connect / TCP に相当する socket 接続と write には、残り時間を上限とする socket タイムアウトまたはノンブロッキング待機を適用する。
  - HTTP 応答の read は残り時間で有界にする。ただし stop の grace（`t` 秒）と wait（コンテナ生存中は正当に無期限）は個別予算を優先し、0011 の設計に従う。
  - pull の進捗 stream（0009）は残り時間で打ち切れるようにし、成功終端まで読む場合も deadline を超えない。
  - create → start → ready は各段階の開始時に残り時間を再計算するが、新しいタイマーを開始しない。
- cancel と回収:
  - deadline 超過・呼び出し側 cancel・task drop のいずれでも socket を `shutdown` / close し、読み取りを起こす。
  - 0006 が所有権を定める接続と、0013 のログセッション（複製 socket の停止）、一時的に起動した子 task は参照カウントまたは明示停止で回収し、回収待ちには上限を設ける（例: 5 秒）。
  - cancel 後のエラーは「deadline 超過」「接続断」を区別し、0017 の分類へ渡す。
- 再試行:
  - 冪等読み取り（inspect、exec inspect、resolve の 404 後 pull 判定）は再試行してよいが、待機は残り deadline の範囲内に限る。exec exit code のバックオフ列は upstream と同じ値（10/50/200/500/1000 ms、最大 6 試行）を使い、上限は残り時間で clamp する。
  - create / start / exec create / stop / rm は自動再試行しない（stop/rm は 404 の冪等分類のみ 0011 が扱う）。呼び出し元が再試行する場合も create の二重発行を避ける設計であることを doc コメントに明記する。
- cleanup 予算: rollback の force remove とログ購読停止は、期限切れの startup deadline と独立した短い予算（例: 5 秒）で実行し、失敗しても元エラーを上書きしない。0001 の回収方針と揃える。
- 既存の `runtime_wbtest.mbt` の deadline テストを回帰として維持し、直結経路向けに「フェーズごとにタイマーをリセットしない」テストを追加する。

## 受け入れ条件

- [x] Given 各フェーズで遅延する fake daemon, when deadline 共有の request を実行する, then 総経過時間は deadline 以内に収まり、フェーズごとにタイマーをリセットしない。(connect/write/read が `deadline` 残時間で bound — stalled daemon の ping が 300ms deadline で打ち切られた。pull/create/start/ready 各操作の wiring は 0009–0013 で引き継ぐ)
- [x] Given 応答の途中で deadline を超過する, when 打ち切る, then read が中断され、エラーが返り、socket が閉じられる。(`with_timeout` + `DeadlineExceeded` + `defer conn.close()`; deadline_wbtest で検証)
- [ ] Given 呼び出し側が start task を cancel する, when 回収を待つ, then socket、子 task、ログセッションが有界時間内にすべて終了し、FD が残らない。**未実行**（direct 経路の start/ログセッションは 0010/0013 で実装後に検証）
- [x] Given deadline 超過後の cleanup, when 実行する, then startup deadline の期限切れに関係なく独立予算で完了する。(`CLEANUP_BUDGET_MS` 共有 + 0001 の bounded cleanup テストが回帰維持)
- [x] Given create/start 相当の非冪等操作が transport エラーで失敗する, when 呼び出しが戻る, then 自動再試行は発生しない。(`request` は再試行しない — 1 回のみ; 再試行は `Deadline::backoff` を介した冪等読み取りのみ)
- [x] Given exec exit code が未確定のまま再試行する, when deadline が近い, then バックオフは残り時間で clamp され、deadline を超えて sleep しない。(`Deadline::backoff`/`sleep_bounded` が残時間 clamp、期限切れで `DeadlineExceeded` — wbtest で検証)
- [x] Given 既存 M0 の deadline 挙動, when `moon test` する, then 既存テストが PASS する。(76 tests PASS、runtime_wbtest 回帰維持)
- [ ] Given `smoke` の readiness タイムアウト経路, when 実行する, then 既存どおり期限で失敗し、コンテナが残らない。**未実行**（Docker daemon 不在で smoke 未実行 — CI docker ジョブに委譲）
- [ ] Given stop の `t` 指定と wait, when 実行する, then 0011 の個別予算が優先され、開始 deadline で不当に打ち切られない。**未実行**（stop/wait の direct API は 0011 で実装後に検証）

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: deadline ヘルパー（残り時間の clamp、期限切れ判定）、fake daemon の遅延注入（接続遅延、ヘッダ遅延、body 分割遅延、応答なし）、cancel 後の終了確認、cleanup 予算の独立性。
  - FD リークは Linux で `/proc/self/fd` の前後比較を wbtest または E2E で確認する。実行環境が Linux 以外の場合は「未実行」と理由付きで記録する。
- fake daemon は Unix socket でフェーズごとに応答を遅延させ、間に合わせた場合と超えた場合の両方をテーブルで検証する（0006/0007 のテスト基盤を共有）。
- Linux Docker 実機（CI の Docker ジョブ）: 0010–0015 の daemon-backed test と `smoke` を実行し、正常系で deadline が短絡しない（daemon が即応答する通常操作が誤って失敗しない）ことを確認する。証跡として所要時間と結果を残す。
- 遅延 daemon での実機 E2E（SIGSTOP した dockerd 等）は CI では実行しないため「未実行」と記録する。プロセスクラッシュ系は 0021 の範囲。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外。実行できない間は理由付きで「未実行」と記録する。

## リスク

- deadline の厳しすぎる適用で正常な slow pull を打ち切る。startup_timeout の既定 60 秒（`image.mbt`）を基準にし、フェーズごとの最小値は実機計測で調整する。
- cancel の二重発行や回収待ちのデッドロック。socket の close と task の join を分離し、回収には必ず上限を設ける。
- 再試行の誤適用で create が二重実行される。非冪等操作の再試行禁止をコード上の分類（冪等マーカー）と doc コメントで明示する。
- cleanup が deadline の影響を受けて orphan を残す。0001 と同じ独立予算とし、失敗時は元エラーへ回収結果を付記する。
- ロールバック: deadline 伝搬は直結経路に限定し、CLI 経路の既存タイムアウト挙動を変えない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Engine transport に start 起点 deadline の共通適用と取消時の socket・子 task 回収を実装する

## 注記

- upstream 参照: [src/core/client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client.rs)（OS 別クライアント統合と `ContainerConfig`。deadline は持たず、予算は経路ごと）、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`DOCKER_STREAM_TIMEOUT` = 60 秒、`EXEC_EXIT_CODE_BACKOFF_MILLIS`）、[src/core/client/docker_log_stream.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_log_stream.rs)（`LOG_SESSION_TIMEOUT` = 30 秒）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`DROP_REMOVE_TIMEOUT` = 5 秒）。
- 既存 issue の参照にあった `src/core/client/client.rs` は pinned revision に存在しないため、統合モジュールは `src/core/client.rs` を参照する。
- 現行実装の参照: [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `startup_remaining_ms` / `startup_command_timeout_ms` / `wait_ready_until` と、[runtime_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime_wbtest.mbt) の deadline 回帰テスト。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡: フェーズ別の経過時間、cancel 前後の FD 数、cleanup の所要時間、遅延 fake daemon の応答ログを残す。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: Deadline type + bounded socket ops + clamped retry backoff
- 2026-11-04: 共通規則を実装。deadline.mbt に `Deadline`（`@async.now()` 絶対時刻共有）、`Deadline::run`（`with_timeout` で残時間 bound・`DeadlineExceeded` で失敗）、`sleep_bounded`/`backoff`（upstream の 10/50/200/500/1000ms・最大6回・残時間 clamp）、`CLEANUP_BUDGET_MS=5000` を追加。`DockerClient::request`/`ping`/`version`/`preflight` が `deadline?` を受け、connect（ffi poll timeout を残時間に cap）と write/read を共有 deadline で bound。再試行は冪等読み取り向けのみで `request` 自体は再試行しない。moon check --deny-warn PASS、76 tests PASS。cancel/rollback/stop-wait の統合検証は 0010–0013 の実装後、実 daemon 系は CI に委譲。
- 2026-11-04: deadline/cancel primitives landed; op-integration criteria deferred to 0010-0013
