# [P0 / M1] Docker exec create/start と stdout/stderr 多重化を移植

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の exec create/start/inspect を直結で実装し、multiplexed stream（8 バイトヘッダ）を stdout/stderr に demux して終了コードと分離した出力を返す。CLI `docker exec` の文字列取得を置き換える土台を作る。

## 背景

- 現行 M0 は `runtime.mbt` の `Container::exec` が `docker exec <id> <cmd...>` を `@shell.Cmd` で実行し、exit code と stdout/stderr の文字列を `ProcessOutput` に詰めるだけ。Docker API の exec create/start/inspect と frame 多重化の扱いを持たない。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、本 issue は 0011 の lifecycle の上に exec を載せる。
- upstream では `src/core/client/docker_client.rs` の `exec` が `POST /containers/{id}/exec`（`AttachStdout: true`、`AttachStderr: true`、`Cmd`、任意の `Env`）→ `POST /exec/{id}/start`（`Detach: false`、`Tty: false`）→ `GET /exec/{id}/json` の順で実行し、start の応答 body を `demux_exec_stream` で分離する。exit code は stream EOF 後に `Running == false` になるまでバックオフ再試行して取得する（`EXEC_EXIT_CODE_BACKOFF_MILLIS` = 10, 50, 200, 500, 1000 ms、最大 6 試行）。`src/core/containers/async_container/exec.rs` は exit code（未確定は `None`）と stdout/stderr リーダーを返す。

## 問題

- exec の出力は Docker では 1 本の multiplexed stream に 8 バイトヘッダ付きで交互に届くが、現行 CLI 経路は 2 本の pipe を直接読むため frame 解析が存在しない。API 直結では demux を自前実装する必要がある。
- 終了コードは `docker exec` の exit code に依存している。API では stream EOF 直後に daemon が exit code をまだ記録していない競合があり、inspect のリトライで確定させる必要がある。
- TTY 有効の exec（`Tty: true`）は frame が付かない raw stream であり、frame として解釈してはならない。この区別が未定義。
- `with_env_var` を exec に引き継ぐ経路がない。Docker API は `Env` を指定するとコンテナ env を置換するため、inspect の `Config.Env` とのマージ規則が必要。

## 目標

- exec create（`POST /containers/{id}/exec`）・start（`POST /exec/{id}/start`）・inspect（`GET /exec/{id}/json`）を直結で実装する。
- multiplexed stream の 8 バイトヘッダ（stream type 1 = stdout、2 = stderr、reserved 3 バイト、payload 長 4 バイト big-endian）を正しく demux し、stdout と stderr を別々に復元する。
- exit code を inspect のリトライで確定し、非ゼロ exit code と出力の両方を返す。
- raw stream（TTY 有効）を frame として誤解釈せず明示エラーにする。
- `Env` を exec で指定できるようにする（コンテナ env への上書きマージ）。

## 対象外

- lifecycle と inspect 基盤は 0011、logs の follow と frame 解析は 0013（frame 形式が共通のため demux ヘルパーは共有できるが、session と有界メモリの扱いは 0013 の責務）。
- exit に基づく readiness（`WaitFor::Exit`）は 0038、healthcheck は 0037。
- LogConsumer と backpressure は 0040。公開エラー型の整備は 0049。同期 Runner は 0043。
- TTY 有効コンテナへの exec / raw stream 出力の対応は本 issue では実装しない（明示エラー）。Apple XPC の exec は M2 の 0028。

## 提案する方針

- `docker_client.mbt`（0010 で新設。実装詳細として変更可）に exec 用の型とメソッドを追加する。
  - create: `{"AttachStdout":true,"AttachStderr":true,"Cmd":[...]}`。`Env` 非空時のみ `"Env":["KEY=VALUE", ...]` を付ける。応答の `Id` を必須で読む。
  - start: `{"Detach":false,"Tty":false}` を送り、応答 body を蓄積上限付きで読む。上限は exec の start 経路として upstream と同じ 64 MiB（`DOCKER_RESPONSE_BODY_LIMIT`）を適用し、超過時は切り詰めずエラーにする（frame 途中切断で出力欠損するため）。
  - inspect: `GET /exec/{id}/json` の `Running` / `ExitCode` を読む。stream EOF 直後の競合に備え、`Running == false` になるまで upstream と同じバックオフ列（10、50、200、500、1000 ms、最大 6 試行）で再試行する。全試行後も `Running == true` の場合は exit code を確定できない。
- demux: 8 バイトヘッダを読み、stream type 1 を stdout、2 を stderr へ、0（stdin）と未知の type は破棄する。複数 frame の連結、payload 長 0、ヘッダが受信チャンク境界で分割されるケースを wbtest で固定する。末尾 frame が途中で切れた場合の寛容動作（完全 frame の内容は保持し、切れた payload の扱いを fixture で固定）は upstream の `demux_exec_stream` に合わせる。
- TTY 非多重化の区別: 本ライブラリは常に `Tty: false` で start する。応答 Content-Type が raw-stream（`application/vnd.docker.raw-stream`）の場合や、`Tty: true` が要求された場合は frame 解析へ進まず明示エラーにする（判定は 0013 の multiplex Content-Type 検証と同じ規則を共有できる）。
- exit code の表現: 公開 `ProcessOutput::exit_code` は現行どおり `Int` を維持する。inspect で確定できない場合は 0 や None 相当を偽らず明示エラーにする（出力は失うが誤った成功を作らない）。公開型を `Option` にするかは 0049 で扱う。
- `Env` のマージ: exec の `Env` 指定時は 0011 の inspect で `Config.Env` を取得し、`KEY=VALUE` を分解して exec 分で上書きマージした配列を送る。空の場合は `Env` を送らず Docker の継承に任せる（upstream と同じ）。
- 公開 `Container::exec` のシグネチャと `ProcessOutput` は変えず、CLI 経路と API 経路で同じ観測結果になることを fixture で比較できるようにする。

## 受け入れ条件

- [ ] Given stdout と stderr が frame 単位で交互に届く, when exec 出力を復元する, then stdout/stderr がそれぞれ正しい順序と内容で分離され、混線しない。
- [ ] Given `exit 7` で stdout と stderr の両方へ出力するコマンド, when exec する, then exit code 7 と両ストリームの出力が復元される。
- [ ] Given payload 長 0 の frame、stdin（type 0）frame、未知 type の frame, when demux する, then stdout/stderr に混入せず、後続 frame の処理が継続する。
- [ ] Given ヘッダが受信境界で分割される, when demux する, then frame として正しく再結合される。
- [ ] Given 蓄積が 64 MiB を超える出力, when start 応答を読む, then 切り詰めず明示エラーになる（ちょうど 64 MiB は成功）。
- [ ] Given raw stream（TTY 有効）の応答, when 解析する, then frame として解釈せず明示エラーになる。
- [ ] Given コンテナ env に `A=1` があり exec に `A=2` を指定する, when exec の request を組み立てる, then `Env` は上書き済みの `A=2` を含み、指定なしの場合は `Env` を送らない。
- [ ] Given exit code がバックオフ後も確定できない, when exec が終わる, then 0 を偽らず明示エラーになる。
- [ ] 既存 CLI 経路の exec テスト（`runtime_wbtest.mbt`）と `smoke` の exec が回帰しない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: multiplexed バイト列の fixture（交互 frame、type 0/未知、payload 0、分割ヘッダ、末尾切断）、`Env` マージ、exit code バックオフ列の試行回数・間隔（fake clock または fake Engine）。
  - fake Engine で exec start を 64 MiB 超（上限を小さく注入した検証モード）と raw-stream 応答にし、エラー分岐を確認する。
- Linux Docker 実機（CI の Docker ジョブ）: Alpine 上で `sh -c 'printf out; printf err 1>&2; exit 7'` を API 経由 exec し、exit code 7 と stdout/stderr 分離を確認する。0010/0011 の daemon-backed test に続けて実行し、証跡を残す。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外（XPC exec は 0028）。CLI adapter の exec 回帰は `smoke_apple` の範囲で確認し、実行できない間は理由付きで「未実行」と記録する。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- frame 解析の取りこぼしで出力が静かに欠損する。境界 fixture を網羅し、末尾切断の寛容動作を fixture で明示的に固定する。
- 64 MiB 上限超過時に exit code も失われる。エラーに上限値と経路を明記し、0049 の分類と整合させる。
- exit code 未確定時のエラー化で、upstream より厳しい挙動になる（upstream は warn + None）。誤った成功を避ける安全側の判断として文書化し、必要なら 0049 で公開表現を再検討する。
- `Env` 指定時の置換セマンティクス（Docker がコンテナ env を置換する）を誤ると環境が欠落する。inspect→マージ→送信の順を固定し、wbtest で確認する。
- 既存 CLI 経路への影響。公開シグネチャを変えず、直結経路を internal API に閉じる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API 直結の exec と multiplexed stream の stdout/stderr 分離を実装する

## 注記

- upstream 参照: [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`exec`、`demux_exec_stream`、`parse_exec_inspect_state`、`resolve_exec_exit_code`、`EXEC_EXIT_CODE_BACKOFF_MILLIS`）、[src/core/containers/async_container/exec.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container/exec.rs)（`ExecResult`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡: multiplexed バイト列 fixture、fake Engine の応答ログ、実機 exec の exit code と分離出力を残す。
- 非 UTF-8 バイト列の扱いは既存 `ProcessOutput`（String）契約に合わせて wbtest で固定し、黙って置換しない。公開型の変更は 0049 と調整する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
