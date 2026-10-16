# [P1 / M1] Docker stdout/stderr の follow/attach と有界取得

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の `GET /containers/{id}/logs` を直結で実装し、follow 付きの継続ストリームと有界メモリの読み取りを提供する。stop/rm 中の購読終了、consumer cancel、64 MiB と 8 MiB の境界を明示的に定義する。

## 背景

- 現行 M0 の `Container::logs`（`runtime.mbt`）は `docker logs` を 15 秒・64 MiB 上限で 1 回取得するだけで、follow（継続取得）も購読タスクの停止も持たない。`docs/PORTING.md` も「log retrieval is not a streaming substitute for the original LogConsumer」と限界を明記している。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、本 issue は 0011 の lifecycle の上に logs を載せる。stop/rm との連動（購読終了）は本 issue の責務。
- upstream の `src/core/client/docker_log_stream.rs` は `?stdout=1&stderr=1&follow=true&tail=all` の常駐セッションを `spawn_blocking` で張り、multiplex frame を demux して stdout/stderr 別の共有バッファ（ストリームあたり 8 MiB・drop-oldest）へ書く。1-shot は `follow=false` で新規セッションを張り、ストリームあたり 64 MiB を超えたら切り詰めずエラーにする。停止は複製ソケットへの `shutdown(Both)` と終端通知で行い、`async_container.rs` の `stop`/`rm` 前に `stop_log_delivery` を呼ぶ。

## 問題

- `runtime.mbt` の `logs_with_timeout` は CLI の一括取得のみで、frame 解析・複数読取者・停止制御がない。長いログを継続して読む手段も、読み取り中に stop/rm された場合に読み取りを終わらせる手段もない。
- follow で無制限に蓄積するとメモリが増え続ける。反対に 1-shot の上限（64 MiB）を超えた場合の扱い（切り詰めか、エラーか）が定義されていない。
- TTY 有効コンテナの `logs` 応答は frame のない raw stream であり、frame として解釈すると壊れる。その区別がない。
- 購読タスクが stop/rm をまたいで残ると、ソケットとタスクがリークする。

## 目標

- 1-shot の logs を API 直結で実装し、ストリームあたり 64 MiB の上限を超えたら切り詰めずエラーにする（既存 `Container::logs` の有界取得契約を維持）。
- follow 付きストリームを実装し、共有バッファをストリームあたり 8 MiB（drop-oldest）に固定して無限蓄積を防ぐ。
- stop/rm の実行時に購読を終了させ、ブロック中の読み取りを有界時間で起こしてタスクとソケットを回収する。
- stdout と stderr を frame 単位で分離し、混線させない。
- TTY 有効（raw stream）の応答を frame として解釈せず明示エラーにする。

## 対象外

- exec の demux は 0012（8 バイトヘッダの形式が共通のためヘルパーを共有できるが、session 管理と有界メモリは本 issue が担当）。
- LogConsumer への継続配信と backpressure は 0040。readiness のログ条件（`WaitFor::MessageOnStdout` 等）の API 直結化は 0011/0036–0039 の範囲で本 issue は読み取り基盤のみ提供する。
- `WaitFor::Exit` / healthcheck は 0038/0037。Apple XPC の logs FD 所有権は M2 の 0029。
- 停止時の exit code 語義は 0041。プロセスクラッシュ後の回収は 0021。Linux 直結 E2E 受入は 0020。

## 提案する方針

- `docker_log_stream.mbt`（新規、実装詳細として変更可）に log session を実装する。0006 の Unix socket transport と 0007 の chunked/stream 解析を利用する。
  - follow: `GET /containers/{id}/logs?stdout=1&stderr=1&follow=true&tail=all`。demux した stdout/stderr をそれぞれ独立した共有バッファへ追記する。バッファ上限はストリームあたり 8 MiB とし、超過時は先頭から捨てる（drop-oldest）。読取側は独立オフセットで読み、上限内では欠落しない。drop-oldest で失われ得ることはコードとテストで明示する。
  - 1-shot: `GET /containers/{id}/logs?stdout=1&stderr=1&follow=false&tail=all` を新規セッションで読み切り、ストリームあたり 64 MiB（upstream `DOCKER_RESPONSE_BODY_LIMIT`）を超えたらエラーにする。`Container::logs` はこの経路を使い、公開シグネチャを維持する。
  - frame 解析: 8 バイトヘッダ（type 1 = stdout、2 = stderr、reserved 3 バイト、payload 長 4 バイト big-endian）。type 0（stdin）と未知 type は破棄する。0012 の demux ヘルパーと共有する。
  - Content-Type 検証: `application/vnd.docker.multiplexed-stream`、`application/octet-stream`、空を許可し、`application/vnd.docker.raw-stream`（TTY 有効）は明示エラーにする（upstream `is_multiplex_content_type` と同じ規則）。
  - セッション起動の検証（接続・ヘッダ読み）には 30 秒の上限（upstream `LOG_SESSION_TIMEOUT`）を設け、成功後は解除する。follow は正当に長時間無ログになり得るため、起動後の受信に固定タイムアウトを掛けない。startup deadline（0018）が有効な文脈では残り予算を上限にする。
- 停止制御: セッションは複製ソケット（`try_clone` 相当）を保持し、外部 stop で `shutdown(Both)` を発行する。読み取りタスクは終端フラグと終端通知を立ててブロック中の読取を起こし、正常終了・panic のどちらでも reader が永久ブロックしないようにする。stop/rm の前に購読を止める（`async_container.rs` の `stop_log_delivery` 相当）。
- consumer cancel: 読取側の drop でセッションを abandon しないよう、参照カウントと能動 stop の 2 経路を用意する（0040 が consumer を接続する際にこの基盤を使う）。
- `runtime.mbt` の `stop`/`rm` は API 経路で購読停止を前置きする。既存 CLI 経路の `logs()` は変更しない。

## 受け入れ条件

- [ ] Given 一定速度でログを出し続けるコンテナ, when follow で購読する, then 各ストリームのバイト列が順序どおり配信され、stdout と stderr が混線しない。
- [ ] Given ストリームあたり 8 MiB を超えるログ, when follow する, then メモリは上限内に留まり、上限超過分の先頭破棄（drop-oldest）が文書と観測で説明できる。
- [ ] Given follow 中に stop または rm する, when 状態が変わる, then 購読タスクは有界時間で終了し、ブロック中の読み取りは起床し、ソケットとタスクが残らない。
- [ ] Given 読取側が drop される（consumer cancel）, when 購読を放棄する, then セッションも有界時間で停止する。
- [ ] Given 1-shot でストリームあたり 64 MiB を超えるログ, when 取得する, then 切り詰めずエラーになる（ちょうど 64 MiB は成功）。
- [ ] Given TTY 有効コンテナの raw stream 応答, when 解析する, then frame として解釈せず明示エラーになる。
- [ ] Given ヘッダが受信チャンク境界で分割される, when demux する, then frame として正しく再結合される。
- [ ] Given 既存 `Container::logs()` の利用, when 直結経路で実行する, then 有界の stdout/stderr が返り、公開シグネチャが変わらない。
- [ ] 既存 CLI 経路の logs テストと `smoke` の logs 取得が回帰しない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 小チャンク分割・早期 EOF・type 0/未知 frame・payload 0・分割ヘッダ・drop-oldest 動作・strict 上限（上限を小さく注入）・Content-Type 判定。
  - fake Engine で follow セッションを張り、stop 発行後に socket shutdown で読み取りが終わることを確認する。
- Linux Docker 実機（CI の Docker ジョブ）: Alpine で周期的に stdout/stderr へ出力するコンテナを起動し、follow で取得 → 途中で stop → 購読終了と `docker ps -a` の残骸なしを確認する。1-shot は既存 `smoke` の logs 経路に加えて API 経路でも取得する。証跡を残す。
- 8 MiB / 64 MiB の実境界は注入上限の wbtest で固定し、実機で 64 MiB のログを生成する確認は行わない（時間・容量が過大なため「未実行」と記録する）。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外（XPC logs は 0029）。実行できない間は理由付きで「未実行」と記録する。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- drop-oldest によるログ欠落。上限と欠落条件をコードと文書に明記し、consumer が追従している通常時に欠落しないことをテストする。
- stop/rm とログ購読の競合でデッドロックや取り残しが起きる。socket shutdown と終端通知の両方を使い、タスク終了を有界で待つ。
- 64 MiB 一括取得はメモリを大きく使う。上限超過はエラーとし、ストリーム読取（follow）を推奨経路として文書化する。
- 起動後タイムアウトの掛け違いで無ログ時に切断される。起動検証にのみ 30 秒を掛け、成功後に解除する。
- ロールバック: 新規ファイルに閉じ、既存 CLI 経路と `logs()` の公開契約を変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API 直結の logs 取得と follow（有界バッファ・停止連動）を実装する

## 注記

- upstream 参照: [src/core/client/docker_log_stream.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_log_stream.rs)（`spawn_log_session`、`SharedLogBuffer`、`FrameDemuxer`、`is_multiplex_content_type`、`DEFAULT_BUFFER_LIMIT` = 8 MiB、`LOG_SESSION_TIMEOUT` = 30 秒）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`stop_log_delivery`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の「Use bounded captured output; log retrieval is not a streaming substitute」を本 issue で解消する。
- 証跡: follow の取得ログ、stop 前後の購読終了時刻、`docker ps -a`、上限注入テストの結果を残す。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
