# [P1 / M3] WaitFor::http と HTTP status/header/body 条件を移植

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0014](./0014-m1-dynamic-published-ports.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

HTTP/1.1 の readiness 待機戦略を MoonBit の型として追加し、port / path / method / header / body / status を照合する。接続拒否と非 HTTP 応答は deadline 内で再試行し、TLS には対応しないことを明示する。

## 背景

- 現行の `WaitFor`（[image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt)）は Nothing / Millis / MessageOnStdout / Stderr / Either / Healthcheck / Exit のみで、HTTP がない。[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `wait_ready_until` は Healthcheck / Exit を未実装として明示エラーにし、[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` も起動前に拒否する。PORTING.md も Readiness の未実装として HTTP を挙げる。
- upstream の `HttpWaitStrategy`（[src/core/wait/http_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/http_strategy.rs)）は path（既定 GET）、`with_port`、method 文字列、request headers、body、response matcher を持ち、`with_expected_status_code` は matcher のショートカット。poll interval の既定は 100 ms、request timeout の既定は 10 秒。
- 照合は受信済みの `HttpResponse`（status / headers / body）で行う。header 名は大文字小文字を区別せず、body は `MAX_HTTP_RESPONSE_BODY_BYTES`（1 MiB）で切り詰めて照合に使う。
- 接続は plain の `TcpStream::connect` + `shiguredo_http11` で、TLS 非対応と doc に明記されている。`Host` ヘッダは IPv6 を `[addr]:port` で括り、`Connection: close` を強制する。`Host` / `Connection` / body あり時の `Content-Length` / auth あり時の `Authorization` と衝突するユーザーヘッダはスキップして warn する。
- ポート未指定時は最初の公開ポートを使い、ホストが IPv6 なら IPv6 ポート、それ以外は IPv4 → IPv6 の順でフォールバックする。接続失敗・プロトコルエラー・条件不一致はいずれも poll interval で再試行し、全体は起動時の startup_timeout で打ち切られる。matcher 未設定と公開ポートなしはループ前の明示エラー。

## 問題

- HTTP readiness が未実装で、nginx 等の HTTP サービスの起動完了を待てない。
- 接続拒否・非 HTTP 応答・条件不一致の再試行方針と、TLS 非対応の扱いが未定義。
- 動的ポート（0014）との接続方法が未定義。

## 目標

- HTTP/1.1 の待機戦略を MoonBit の型で表現し、port / path / status / header / body を照合できる。
- 条件不一致・接続拒否・非 HTTP 応答を deadline 内で再試行し、超過時は確実に失敗する。
- TLS / HTTPS を成功と誤認しない。
- 既存の log / duration waits と同じ共有 deadline で動作する。

## 対象外

- Healthcheck（0037）、exit / exec waits（0038）、複数 ready conditions の合成（0039）。
- Basic / Bearer 認証ヘッダと任意クロージャ matcher（upstream の `with_basic_auth` / `with_bearer_auth` / `with_response_matcher`）。必要になった時点で別 issue とする。
- TLS / HTTPS 対応。plain HTTP のみを対象とする。
- CLI adapter での HTTP wait 対応（0004 の方針どおり未対応のまま拒否する）。

## 提案する方針

- 新規 `http_wait.mbt`（実装詳細として変更可）に `HttpResponse` 相当（status / headers / body）と `HttpWaitStrategy` 相当（path、port、method、request headers、request body、expected status、expected header、expected body、poll interval、request timeout）を定義し、[image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `WaitFor` へ HTTP の variant とコンストラクタ（例: `WaitFor::http(path)`）を追加する。ビルダー名は MoonBit の命名規約に合わせて実装時に決定する。
- `WaitFor` を列挙する既存の match（`build_run_args` と `wait_ready_until`）を更新し、CLI adapter では副作用前に拒否、native 経路（M1 / M2）では実行する。追加漏れは `--deny-warn` のコンパイルで検出する。
- リクエスト構築: 0007 の HTTP/1.1 framing を再利用し、`Host`（IPv6 は括弧付き）と `Connection: close` を強制する。予約ヘッダと衝突するユーザーヘッダはスキップして診断ログに残す。
- 送信: 0014（Linux）/ 0030（XPC）の公開ポート解決 API で host / port を求め、TCP 接続する。1 回の接続〜受信を request timeout（既定 10 秒）で打ち切り、poll interval（既定 100 ms）で再試行する。response body は 1 MiB まで保持して照合する（切り詰めはエラーにしない）。
- 失敗分類: 接続拒否（接続・解決失敗）、非 HTTP 応答（解析失敗）、条件不一致の 3 種に内部で分類し、いずれも deadline 内は再試行する（upstream は一律 debug + retry で、全体の打ち切りは startup_timeout が担う）。deadline 超過時のエラーには最後の分類を含める。
- 事前検証: matcher に相当する条件（expected status / header / body）が 1 つもない場合は接続前にエラー、公開ポートがない場合も接続前にエラー。ポート未指定時の選択規則は upstream と同じ「最初の公開ポート（IPv4 優先、キー最小）」とし、docs に明記する。
- TLS 非対応: plain TCP のみを実装し、TLS のハンドシェイクバイト列は解析失敗として扱う。HTTPS の成功を誤認しないことを docs とテストで固定する。

## 受け入れ条件

- [ ] Given nginx が起動して `GET /` に 200 を返す, when `WaitFor::http("/")` と expected status 200 で待つ, then deadline 内に成功する。
- [ ] Given 起動直後で接続が拒否される, when HTTP wait する, then 接続拒否として再試行し、起動後の応答で成功する（即時失敗しない）。
- [ ] Given 条件不一致（例: 404）が deadline まで続く, when HTTP wait する, then エラーで終了し hang しない。
- [ ] Given 非 HTTP バイト列（TLS ハンドシェイク等）を返す, when HTTP wait する, then 成功と誤認せず deadline で失敗する。
- [ ] Given 同名ヘッダの大文字小文字違い, when 照合する, then 区別せず一致する。
- [ ] Given 1 MiB を超える body, when 照合する, then 先頭 1 MiB で照合を継続する（切り詰めを致命的エラーにしない）。
- [ ] Given 応答が request timeout を超える, when 送信する, then その回を打ち切って次の poll へ進む。
- [ ] Given log / duration wait と HTTP wait を併用する, when 全体の deadline を超過する, then startup_timeout を超えずに失敗する。
- [ ] Given matcher 条件なし、または公開ポートなし, when wait を開始する, then 接続試行の前にエラーになる。
- [ ] `WaitFor::http` は CLI adapter では副作用前に拒否され、native 経路でのみ動作する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: リクエスト構築（Host / IPv6 の括弧 / `Connection: close` / 予約ヘッダのスキップ）、応答照合（status / header の大小文字 / body / 1 MiB 切り詰め）、分類付き再試行の状態機械、ポート未指定時の選択規則、設定エラーの事前検出。
- native 統合テスト: ローカルの TCP fixture サーバー（非 HTTP バイト列、遅延応答、接続拒否）を立てて、分類と timeout の挙動を確認する。fixture の起動方法は実装時に決定する。
- Docker 実機（CI の Linux Docker ジョブ）: `nginx:alpine` を起動して 200 を待つ、存在しない path で deadline 失敗、動的ポート（0014）との組み合わせ、startup_timeout の全体遵守を実行する。終了後に `docker ps -a` で残存ゼロを確認する。
- Apple 実機（XPC。CI に物理 Mac は存在しない）: 0032 の受入項目として実施する。実行できるまで「未実行」と記録し、CI compile-only で代用しない。

## リスク

- retry ループの busy spin: poll interval を必須にし、deadline を単一の clock で管理する。
- body の 1 MiB 切り詰めが照合を誤判定する: 「先頭 1 MiB で照合」を契約として docs に明記する。
- IPv6 環境差: IPv4 → IPv6 のフォールバックを upstream と同じ順序にし、環境は実機ログに残す。
- 「最初の公開ポート」の決定規則が暗黙になる: docs に明記し、テストで固定する。
- ロールバック: `WaitFor` への追加は既存 match に影響するため、CLI adapter の拒否を維持したまま追加し、非退行をテストする。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] HTTP/1.1 の readiness 待機（status/header/body 照合、有界 retry）を実装する

## 注記

- 主な参照: [src/core/wait/http_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/http_strategy.rs)（定数は request timeout 既定 10 秒、body 上限 1 MiB、poll interval 既定 100 ms）。
- 証跡: HTTP request / response の記録、deadline 超過までのリトライログ、非 HTTP 応答で失敗したログ、`docker ps -a` の前後。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。Docker 側の HTTP framing は 0007、動的ポートは 0014、XPC のポート解決は 0030 に依存する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
