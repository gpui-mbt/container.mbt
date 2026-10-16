# [P1 / M3] stop_with_timeout と exit code 語義を揃える

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0027](./0027-m2-xpc-stop-remove.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`Container::stop` に grace 時間の指定を追加し、未指定 / 0 / 正値 / 負値の意味論を定義した上で、停止後の exit code を取得する API を追加して SIGKILL による強制終了と graceful 終了を区別できるようにする。

## 背景

- 現行の [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `Container::stop` は [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_stop_args(id)` が返す固定 `["stop", id]` を 30 秒 timeout で実行するだけで、grace 指定も exit code 取得もない。
- upstream の [src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) は `stop_with_timeout(Option<i32>)` を提供し、`None` はデフォルト 30 秒の SIGTERM、`Some(0)` は即時 SIGKILL、負値は macOS では i32::MAX 秒相当・Linux では 30 秒に変換する。`exit_code()` はバックグラウンドの wait が観測した値を世代チェック付きで返し、再 start 後の旧世代の値を混入させない。
- Apple CLI には `container stop -t/--time`（デフォルト 5 秒）と `container kill`（デフォルト SIGKILL）が存在する。Docker CLI には `docker stop -t` と `docker kill` が存在する。`container inspect` の文書化された出力には exit code が含まれておらず、実測での確認が必要。

## 問題

- grace 時間を指定できないため、SIGTERM を trap して後処理するコンテナに十分な時間を与えられない。反対に固定 30 秒待ちは短命 fixture のテストを遅くする。
- `stop` 後に exit code を取得する API がなく、SIGKILL による強制終了と graceful 終了をテストから区別できない。
- 停止直後の race（停止コマンド成功直後はまだ inspect が running を返し得る）に対する扱いが未定義。
- 既存 `stop()` の 30 秒固定という暗黙の語義がドキュメント化されていない。

## 目標

- `stop_with_timeout(seconds : Int?)` 相当を追加する。`None` / 負値は 30 秒の grace、`Some(0)` は即時強制 kill、正値はその秒数の grace として扱う。
- Docker は `stop -t <sec>`（0 は `kill`）、Apple は `stop --time <sec>`（0 は `kill`）に反映する。
- `exit_code()` 相当で停止後の終了コードを取得できる。SIGKILL と graceful の区別に使える（具体的なコード値は環境依存のためテストでは生値を固定しない）。
- exit code を取得できない場合は `None` または明示エラーで返し、古い値を返さない。キャッシュしない。
- 停止直後の race は有界リトライで最終状態を待つ。
- 既存 `stop()` の呼び出しがデフォルト挙動（30 秒 grace）で回帰しない。

## 対象外

- pause / unpause 等の他のライフサイクル操作。
- XPC の stop / remove 実装そのもの（0027）。本 issue は CLI adapter 経路と、経路非依存の語義定義を扱う。
- ウォッチドッグやスコープ cleanup（0042）。
- exit 待機条件としての統合（0038。本 issue の `exit_code()` を 0038 が利用する）。
- Docker Engine API / XPC の stop 実装詳細（0011 / 0027 が所有）。

## 提案する方針

- [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) に `build_stop_args(runtime, id, grace_seconds : Int?)` を追加する。Docker は `["stop", "-t", sec, id]`、Apple は `["stop", "--time", sec, id]`。`Some(0)` は Docker `["kill", id]` / Apple `["kill", id]` に切り替える。既存 `build_stop_args(id)` は互換のため残すか、呼び出し元を置き換える（実装詳細として変更可）。
- grace の正規化は純関数 `normalize_stop_grace(value : Int?) -> Int` にする。`None` と負値は 30、`Some(v)`（v >= 0）は v。upstream の macOS が負値を i32::MAX 秒に変換する挙動は採用しない（CLI adapter が最大 24 時間ブロックする事故を避ける）。この差異は注記と doc に明記する。
- [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) に `Container::stop_with_timeout(seconds : Int?)` を追加し、既存 `stop()` は `stop_with_timeout(None)` へ委譲する。
- `Container::exit_code()` を追加する。Docker は 0011 の inspect 経路（M1 前は `docker inspect` 相当）で `State.ExitCode` と running を読む。Apple は `container inspect` の出力に exit code が含まれるかを実測で確認し、取得できる場合のみ提供する。取得できない場合は、停止済みでも `None` を返すか、対応経路では明示エラーにする（実装時に決定し doc に書く）。
- 停止直後の race: 停止コマンド成功後に実行状態を読み、終了済みと exit code が確定するまで 100 ms 間隔の有界リトライ（上限は grace 秒 + 数秒程度。実装時に固定）を行う。値をキャッシュせず、呼び出しごとに取得する。
- エラー分類: stop 自体の失敗（実行中でない等の冪等ケースを含む）と exit code 取得不能を区別する。停止済みコンテナへの stop は冪等に成功扱いする（0011 の方針と整合）。

## 受け入れ条件

- [ ] Given SIGTERM を trap して後処理してから終了する fixture, when `stop_with_timeout(Some(10))` する, then grace 内に終了し、`exit_code()` が graceful 終了を示す値で取得できる。
- [ ] Given SIGTERM を無視する fixture, when `stop_with_timeout(Some(1))` する, then 1 秒後に強制終了され、`exit_code()` の値が graceful 終了と区別できる。
- [ ] Given `Some(0)`, when stop する, then grace 待ちをせず kill 経路が呼ばれる。
- [ ] Given `None` または負値, when stop する, then 30 秒 grace として扱われる（組み立て引数で確認できる）。
- [ ] Given 停止直後に `exit_code()` を呼ぶ, when 状態がまだ確定していない, then 有界リトライで最終値を返し、取得不能時は `None` または明示エラーになる。
- [ ] Given 既存の `stop()` 呼び出し, when 実行する, then 従来と同じデフォルト挙動になる。
- [ ] 既存 smoke の stop / rm に回帰がない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: `normalize_stop_grace` の分岐（`None` / -1 / 0 / 1 / 大きい値）、`build_stop_args` の Docker / Apple 別組み立て（kill 切替を含む）、引数バリデーションを検証する。
- Linux Docker 実機（CI の Docker ジョブ）で SIGTERM / SIGKILL fixture を実行する。
  - graceful fixture: `trap` で終了処理をして exit する小さなスクリプト。
  - forced fixture: SIGTERM を無視するスクリプト。`stop_with_timeout(Some(1))` 後の `exit_code()` を記録する。
  - 生の値は環境依存のため、テストは「graceful と forced が区別できること」「graceful 側が期待どおり 0 であること」で判定する。
- Apple Silicon 実機: `container stop --time` / `container kill` の挙動と `container inspect` の exit code 有無を実測する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 / 0027 の実機受入時に併せて実施する。exit code が取得できない場合は制限事項として文書化する。
- テスト用コンテナは固有 name に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- Apple の `--time` / kill のセマンティクスが Linux と微妙に異なる可能性。実測結果を優先し、差異は doc に記録する。
- exit code の生値（128 + シグナル番号等）はプラットフォーム・ランタイムで揺れ得る。テストは区別可能性で判定し、固定値に依存しない。
- 停止直後のリトライが失敗パスのレイテンシを増やす。上限を短く固定し、deadline とは独立させる。
- 負値の正規化を upstream macOS と変える判断は互換差になる。意図的な差異として CHANGES と doc に残す。
- ロールバック: 既存 `stop()` は委譲に置き換えるだけで引数を変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] stop の grace 時間指定と停止後 exit code 取得（graceful / 強制終了の区別）を追加

## 注記

- upstream の対応物: [src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) の `stop_with_timeout` / `exit_code` / wait_state の世代管理。
- Apple CLI 仕様の参照: `container stop` の `-t/--time`（デフォルト 5）と `container kill`、`container inspect` は実装時に実機で再確認する（文書化された inspect 出力に exit code は見当たらない）。
- 関連: 0011（inspect）、0027（XPC stop/remove）、0038（exit 待機）、0042（cleanup 契約）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Start / exec / stop / rm / logs 行。
- 証跡要件: stop の引数、grace 経過、取得した exit code と判定（graceful / forced）をログまたは artifact に残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
