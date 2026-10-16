# [P1 / M1] Docker API ステータスと失敗分類を実装

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の HTTP 応答を、操作の文脈付きで失敗分類する。同じ 404 でも image not found、container not found、container path not found を分離し、401/403/409/5xx を操作名とともに区別する。エラー body は容量上限付きで読み、分類できない場合は fail closed にする。

## 背景

- 現行 M0 は CLI の exit code と stderr 文字列だけで失敗を扱い、「何をしようとして何が存在しないのか」を判別できない。M1 は Docker Engine API に Unix socket で直結し、HTTP ステータスと daemon のメッセージから失敗を分類する必要がある（CLI 非依存）。
- 分類の基盤は 0007 の HTTP 応答解析と 0006 の transport。本 issue は直結クライアント全体（0010 create/start、0011 lifecycle、0012 exec、0013 logs、0014/0015 inspect、0016 認証）が使う共通の失敗分類を提供する。
- upstream の `src/core/error.rs` は `ClientError::ImageNotFound` / `ContainerNotFound` / `ContainerPathNotFound` / `Configuration` / `Json` / `Other` と `Error::PortNotExposed` を持つ。`src/core/client/docker_client.rs` は `resolve_image_descriptor` の 404 を `ImageNotFound`、`inspect_json` の 404 を `ContainerNotFound` にし、archive の 404 は body の `message` が `Could not find the file ` で始まるときだけ `ContainerPathNotFound`（それ以外は `ContainerNotFound`）にする。その他の >=400 は操作名付きの `Other`（例: `failed to stop container: {status}`）で、pull は body の `message` を含める（`pull_error_message`）。

## 問題

- 直結経路に失敗分類がなく、全失敗が同じ文字列エラーになる。0011 の冪等化（404 を成功扱い）と 0014/0015 の「存在しない」エラーが、同じ 404 を区別できない。
- 401/403（認証・権限）、409（名前衝突・状態競合）、5xx（daemon 障害）の区別がなく、再試行や利用者への案内の判断材料がない。
- エラー body の読み取り上限が未定義。巨大な body を無制限に読む余地がある。
- daemon のエラーメッセージに何を含めてよいか（認証情報を混ぜない）が未定。

## 目標

- 操作文脈付きの失敗分類を内部型として実装する。
  - 404: 操作ごとに image / container / container path の不存在へ分離する。archive は daemon `message` の接頭辞でパス不存在を判定し、判別できない場合は container not found に寄せる（upstream と同じ安全側）。
  - 401/403: 認証・権限の失敗を操作名付きで返す。
  - 409: 競合（名前衝突、状態競合）を操作名付きで返す。
  - 5xx: daemon 障害をステータスと操作名付きで返す。
- daemon の `message` を読める場合は分類メッセージへ含め、読めない場合はステータスのみで分類する（fail closed）。
- エラー body に容量上限を適用し、超過時は切り詰めずエラーにする。
- 分類結果が決定論的で、fixture 比較できるようにする。

## 対象外

- HTTP 応答・chunked・stream の解析そのものは 0007。transport は 0006。
- 操作（create/start/stop/rm/wait/exec/logs/pull）の実装は 0010–0016。本 issue は分類の共通部品を提供する。
- 404 を成功として扱う冪等判断は 0011 側の責務（本 issue は分類だけ返す）。
- 公開エラー型と失敗マトリクスの一貫性検証は 0049。本 issue の分類型は internal とし、公開表現は 0049 で決める。
- 再試行戦略は 0018。Apple XPC のエラー表現は M2。Podman 互換の差異は 0022。入力ファズと資源リークの系統検証は 0054。

## 提案する方針

- 新規ファイル（例: `engine_error.mbt`、実装詳細として変更可）に internal の分類型と分類関数を置く。例: image not found、container not found、container path not found、unauthorized、forbidden、conflict、server error、malformed response、body too large、transport error。各 variant は操作名と対象（image 参照、コンテナ ID、パス等）を保持する。
- 分類関数の入力は「HTTP ステータス、daemon body（上限内）、操作文脈、対象」とする。責務を分離し、wbtest でテーブル駆動比較する。
  - 404 の分離: 呼び出し側が操作文脈（resolve/pull、inspect/lifecycle/exec、archive）を渡し、archive のみ body `message` の `Could not find the file ` 接頭辞（upstream `classify_archive_404` と同じ規則、`starts_with` で判定）で path not found にする。
  - `message` は JSON `{"message": "..."}` から取り、非 JSON・欠落・非文字列は「メッセージなし」としてステータスのみで分類する。
  - 401/403/409/5xx は操作名とステータス、可能なら `message` を含める。メッセージ本文の例は upstream の `failed to stop container: {status}` や `failed to pull image {descriptor}: {status}: {message}` に倣う。
- body 上限: エラー応答の読み取りにも 0007 の上限機構を使い、経路ごとの上限（exec/logs/copy/pull は 64 MiB、その他は 0007 の既定）を超えたら `body too large` としてエラーにする。切り詰めた body を分類に使わない。
- 秘密情報: リクエストヘッダ（`X-Registry-Auth` 等）と資格情報をエラーへ含めない。daemon `message` をそのまま含める場合も 0016 の非漏出方針と整合させる。0011 の冪等化は「container not found」の variant を明示的に判定して行う。
- transport/接続断は 0018 の deadline 分類と接続断とを区別できる variant にし、操作名を保持する。
- 資源管理: 分類経路を含むすべての応答処理で socket を閉じる。エラー分岐でも接続とバッファを解放する（0018 の cancel と併せて確認する）。

## 受け入れ条件

- [ ] Given inspect が `{"message":"No such container: ..."}` 付きの 404, when 分類する, then container not found になり、対象 ID を保持する。
- [ ] Given stop/rm が 404, when 分類する, then container not found が返り、呼び出し側（0011）が冪等成功へ変換できる。
- [ ] Given image resolve/pull が 404, when 分類する, then image not found になり、container not found と区別される。
- [ ] Given archive が `{"message":"Could not find the file /no/such in container x"}` 付きの 404, when 分類する, then container path not found になり、リクエストのパスを保持する。
- [ ] Given archive が上記以外の文言・空 body・非 JSON の 404, when 分類する, then container not found に寄せられる（誤って path not found にしない）。
- [ ] Given 401 または 403, when 分類する, then 認証・権限の失敗として操作名付きで返り、資格情報を含まない。
- [ ] Given 409, when 分類する, then 競合として操作名付きで返る。
- [ ] Given 5xx, when 分類する, then daemon 障害としてステータスと操作名付きで返る。
- [ ] Given 上限を超えるエラー body, when 読む, then 切り詰めず body too large として失敗する（分類に部分 body を使わない）。
- [ ] Given 同一の失敗応答, when 繰り返し分類する, then 同じ分類結果になる（決定的）。
- [ ] Given エラー経路, when 応答処理が終わる, then socket が閉じられ、FD が残らない。
- [ ] 既存の CLI 経路のエラー文面テストが回帰しない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: ステータス × 操作文脈 × body の分類テーブル（401/403/404/409/5xx、message あり/なし/非 JSON/空、archive の接頭辞判定、上限超過）。
- fake Engine（Unix socket）でエンドポイントごとにスクリプト化した応答（401/403/404/409/500）を返し、分類と FD 解放（`/proc/self/fd` の前後比較）を Linux の wbtest または E2E で確認する。
- Linux Docker 実機（CI の Docker ジョブ）: 存在しない image の resolve（404）と、存在しないコンテナ ID の inspect / exec（404）を実機で分類し、container not found と image not found が実際の応答から分離できることを確認する。証跡として応答 body と分類結果を残す。
- archive のパス不存在 E2E は copy_from（0034）未実装のため、fixture ベースの確認に留め、E2E は「未実行」と理由付きで記録する。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外。実行できない間は理由付きで「未実行」と記録する。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- 404 の誤分類で「存在しないコンテナ」を「存在しないパス」と誤診断する。upstream と同じく接頭辞一致のみを path not found とし、不明は container not found に寄せる。
- daemon のメッセージ文言変更で分類が壊れる。接頭辞判定を fixture で固定し、分類不能時は fail closed（安全側）にする。
- エラー body の読み過ぎでメモリを使う。上限超過はエラーにし、部分 body を分類に使わない。
- エラーに資格情報が混入する。ヘッダや config を分類材料にせず、0016 と共通の非漏出テストを用意する。
- ロールバック: 新規ファイルと直結クライアントからの呼び出しに限定し、CLI 経路の文字列エラーを変えない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API の失敗分類（操作文脈付き 401/403/404/409/5xx と not found の分離）を実装する

## 注記

- upstream 参照: [src/core/error.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/error.rs)（`ClientError`、`Error::PortNotExposed`）、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`resolve_image_descriptor`、`inspect_json`、`classify_archive_404`、`parse_daemon_error_message`、`pull_error_message`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の「API-level error classification 未対応」を本 issue で解消する。
- 証跡: 分類テーブルのテスト結果、fake Engine の応答ログ、実機 404 の応答 body と分類結果を残す。
- 公開エラー表現の確定は 0049 に依存するため、本 issue では internal 型と決定的な分類を与えるところまでとする。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
