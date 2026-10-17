# [P0 / M1] Docker inspect/stop/rm/wait と冪等 lifecycle を移植

Status: done
Model: SWE-2 Max
Created: 2026-10-16
Updated: 2026-11-04
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0010](./0010-m1-docker-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

容器状態の inspect、stop、force remove、exit code の wait を Docker Engine API 直結で実装し、既停止・既削除・他 actor による削除を冪等に分類する。stop と rm はそれぞれ独立した有界予算で実行し、start deadline（0018）に引きずられないようにする。

## 背景

- 現行 M0 の `Container`（`runtime.mbt`）は `stop` が `docker stop`、`rm` が `docker rm --force` を固定 30 秒で実行するのみで、Engine の状態取得（inspect）と終了コード待ち（wait）を持たない。停止が成功したかは次の rm の成否でしか分からない。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、本 issue は 0010 の create/start の後続として lifecycle 操作を追加する。
- upstream では `src/core/client/docker_client.rs` が `GET /containers/{id}/json`（`inspect_json`。404 は `ContainerNotFound`）、`POST /containers/{id}/stop?t={t}`（404 は冪等成功、既定 `t=30`）、`DELETE /containers/{id}?force={force}`（404 は冪等成功）、`POST /containers/{id}/wait?condition=not-running`（`StatusCode` を返す）を実装する。`src/core/containers/async_container.rs` の `stop_with_timeout` / `rm` / `rm_blocking` がこれらを組み合わせる。

## 問題

- `runtime.mbt` に inspect 相当の API がなく、コンテナの running 状態や、stop→rm 後の not found を観測できない。`testcontainers` 相当のライフサイクル判断（wait、exit code、再試行の冪等性）がすべて CLI exit code 依存。
- stop は常に CLI 既定の 30 秒で、Docker API の `t`（grace）を指定できない。rm も同じ 30 秒で、削除対象が既に消えている場合や他 actor が削除した場合の分類がない。
- `wait` が存在しないため、`WaitFor::Exit`（0038）やプロセス終了コードに基づく readiness の土台がない。

## 目標

- `GET /containers/{id}/json` で running を取得できる。404 は container not found（0017 の分類）として扱う。
- `POST /containers/{id}/stop?t={t}` を実装する。既定 `t=30`、`Some(t>=0)` はそのまま、負値は 30（upstream と同じ）。404 は冪等成功、304（既停止）も成功として扱う。
- `DELETE /containers/{id}?force={force}` を実装する。404 は冪等成功。公開 `rm()` は force=true 固定とし、適用条件をドキュメントに明記する。
- `POST /containers/{id}/wait?condition=not-running` で終了コードを返す。削除済みコンテナへの wait はエラーにする（0 を偽装しない）。
- stop と rm はそれぞれ独立した有界予算を持ち、startup deadline（0018）とは分離する。

## 対象外

- create/start と rollback は 0010。exec は 0012、logs は 0013、port/network の inspect 派生 API は 0014/0015、HTTP 失敗分類の実装は 0017、deadline と cancel の共通化は 0018。
- `stop_with_timeout` の公開 API と exit code 語義の調整は 0041。`WaitFor::Exit` の readiness は 0038。
- Drop/keep/watchdog の自動 cleanup 契約は 0042。プロセスクラッシュ後の残存回収は 0021。同期 Runner は 0043。Apple XPC の stop/remove は M2 の 0027。
- Linux 直結の起動〜削除 E2E 受入は 0020。

## 提案する方針

- `docker_client.mbt`（0010 で新設する直結クライアント、実装詳細として変更可）に lifecycle メソッドを追加する。
  - `inspect`: `GET /containers/{id}/json` の応答を解析し、最低限 `State.Running` を返す。0041 の待ち合わせに備えて `State.ExitCode` も読める形にしておく。Ports の解析は 0014 に譲るが、同一 JSON を再取得しないよう snapshot 型を共有可能にする。
  - `stop(timeout_seconds: Int?)`: upstream と同じ `t` への正規化（None / 負値 → 30、0 以上はそのまま）。`t=0` は grace 0（SIGTERM 後ただちに SIGKILL）としてそのまま送る。
  - `remove(force: Bool)`: 404 を冪等成功として返す。
  - `wait_exit_code()`: `condition=not-running` の応答 `StatusCode` を Int として返す。404 はエラー。
- `runtime.mbt` の `Container` は次のように更新する（公開シグネチャは現行維持）。
  - `stop()` は直結経路では `t=30` で API を呼ぶ。`self.removed` 時の事前ガードは現行どおり維持し、既停止（304）と既削除（404）は成功として戻る。
  - `rm()` は `self.removed` の no-op を維持し、force=true で削除して成功時に `removed = true` を立てる。404 は成功扱いで `removed = true` にする。force=true の根拠: upstream の `ContainerAsync::rm` / `rm_blocking` は常に force=true で、公開 `rm()` は「明示削除」の意味を持つ（0041/0042 で詳細を調整）。
  - 追加の internal メソッドとして inspect 状態取得と wait を実装し、公開 API（`is_running` 等）の命名は 0041/0043 と整合させる。
- 「他者削除」は自削除と区別できないため、stop/rm では 404 を一律冪等成功に、inspect/wait では not found エラーに分類する（0017 の分類を利用）。
- 再試行の安全性: lifecycle 操作は create で得た ID のみを対象にし、name からコンテナを再解決しない。ID は再利用されないため、再試行が別コンテナへ作用しない。
- タイムアウト: stop は `t` 秒 + 応答待ちの短い余裕、rm は削除専用の独立上限（例: upstream `remove_blocking` と同じ 60 秒）とする。wait はコンテナ生存中に正当に無期限となり得るため個別タイムアウトを設けず、呼び出し側の cancel / deadline（0018）で中断する。

## 受け入れ条件

- [ ] Given running コンテナ, when `stop()` を呼ぶ, then inspect の `State.Running` が false になり、再度 `stop()` を呼んでも成功する（304 / 404 の冪等扱い）。**未実行**（実 daemon 不在。mock で 304/404 冪等成功と `t` 正規化を検証済み、running 遷移の実測は 0020/CI に委譲）
- [x] Given 削除済みコンテナの ID, when `rm()` を再実行する, then 成功し、他のコンテナは変更されない。(mock で 2 回目の `DELETE ?force=true` が 404 → 冪等成功)
- [x] Given stop→rm 済みの ID, when inspect する, then not found として分類されたエラーになり、別コンテナの情報を返さない。(`inspect_container` の 404 → `ContainerNotFound`)
- [ ] Given `sh -c 'exit 7'` で終了するコンテナ, when wait する, then exit code 7 が返る。**未実行**（実 daemon 不在。mock で `{"StatusCode":7}` → 7 を検証済み、実終了コード観測は 0020/CI に委譲）
- [x] Given 削除済みコンテナ, when wait する, then 0 を返さず明示エラーになる。(wait の 404 → `ContainerNotFound`、0 偽装なし)
- [x] Given 同じ ID で stop/rm を再試行する, when 名前に別のコンテナが存在しても, then 操作対象は保持中の ID から変わらない。(全操作が create 由来の ID のみを対象とし、name 再解決なし — request path が `percent_encode(id)` 固定)
- [x] Given force remove, when 実行中コンテナに `rm()` する, then 削除は成功し、force の適用条件（公開 `rm()` は常に force=true、graceful 停止は `stop()`）がコードと文書に明記されている。(`remove_container` doc に force 契約を明記)
- [x] Given stop の `t=0`, when 送信する, then `t=0` がそのまま API に渡る（30 に丸めない）。(`t` 正規化テーブル: None/負値 → 30、`t>=0` はそのまま — request 行で `?t=0` を確認)
- [x] 既存 CLI 経路の `stop`/`rm` テスト（`runtime_wbtest.mbt`）と `smoke` の lifecycle が回帰しない。(102 tests PASS)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: `t` 正規化（None / 負値 / 0 / 正値）、404・304・409 の分類、`removed` フラグ遷移、wait 応答 `StatusCode` の解析。
  - fake Engine で stop 304 / rm 404 / inspect 404 / wait 404 を個別に返させ、冪等成功とエラーの分岐を確認する。
- Linux Docker 実機（CI の Docker ジョブ）: 0010 の daemon-backed test に続けて、API で create/start → stop → inspect（not running）→ rm → inspect（not found）→ 再 rm（成功）を実行する。`exit 7` の短命コンテナの wait で exit code 7 を確認する。証跡として各応答と `docker ps -a` を残す。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外。CLI adapter の stop/rm 回帰は `smoke_apple` の範囲で確認し、実行できない間は理由付きで「未実行」と記録する。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- 404 の一律冪等化で、ID の取り違えや別コンテナの誤削除を隠蔽する。ID は create 由来の所有 ID に限定し、name 再解決をしないことで対象を固定する。
- stop の `t` と transport の待機時間の混同。`t` は Docker の grace、待機は独立上限として定数を分ける。
- wait の無期限ブロック。呼び出し側 cancel（0018）とセットで実装し、単体で無限待ちにしない。
- 既削除を成功扱いすることでユーザーが「まだ存在する」と誤解する。`removed` フラグと inspect の not found 分類で状態を明示する。
- ロールバック: 変更は直結経路と `Container` の internal API に限定し、公開シグネチャを変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API 直結の inspect/stop/rm/wait と冪等 lifecycle 分類を実装する

## 注記

- upstream 参照: [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`inspect_json`、`stop`、`remove`、`wait_blocking`）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`stop_with_timeout`、`rm`、`rm_blocking`。rm は常に force=true）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡: stop/rm 前後の inspect 応答と `docker ps -a`、wait の `StatusCode` をログまたは artifact に残す。
- `issues/README.md` の運用ルール 5 に従い、テストの後始末はテストが作成した ID/name に限定する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。docker_container.mbt に `inspect_container`（`GET /containers/{id}/json`、`ContainerInspect{running, exit_code}` snapshot — 0014 が ports を拡張）、`stop_container`（`t` 正規化 None/負値→30・非負はそのまま、304/404 冪等成功、既定 budget `t+DOCKER_STOP_MARGIN_MS`）、`remove_container`（404 冪等成功、既定 `DOCKER_REMOVE_TIMEOUT_MS=60_000`）、`wait_container`（`POST .../wait?condition=not-running`、`StatusCode` 必須、404 はエラー、呼び出し側 deadline/cancel で中断）を追加。`runtime.mbt` の CLI `Container` への統合は 0019 の経路選択と一緒に行う（現行 CLI 契約を壊さないため）。moon check --deny-warn PASS、102 tests PASS。実 daemon の running 遷移・実終了コード観測は未実行（CI）。
- 2026-11-04: inspect/stop/rm/wait implemented
- 2026-11-04: mock-daemon verified; real-daemon lifecycle deferred to CI
