# [P2 / M3] 環境変数待ちと複数 ready conditions の意味論

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M3
Depends on: [0036](./0036-m3-http-readiness.md), [0037](./0037-m3-healthcheck-readiness.md), [0038](./0038-m3-exit-cmd-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

環境変数からミリ秒待機を組み立てる `WaitFor::millis_in_env_var` 相当を追加し、複数 ready conditions の実行順序・途中失敗・deadline 消費の意味論を upstream の確認できる挙動に合わせて固定する。

## 背景

- upstream の [src/core/wait/mod.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/mod.rs) は `WaitFor::millis_in_env_var(name)` を持ち、環境変数が未設定または不正値の場合は `WaitFor::Nothing` を返す（`std::env::var` と数値 parse に失敗したら空条件になる）。複数 conditions は `block_until_ready` が配列順に `wait_until_ready` を呼び、最初のエラーで後続を実行しない。
- upstream の [src/core/wait/log_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/log_strategy.rs) は空メッセージを常にマッチ扱いで即成功にする。ログは追記型なので、EOF 相当を観測しても直ちに失敗にせず、プロセス終了後は猶予をもって読み続ける。
- MoonBit 側の [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) は conditions を配列順に処理し、各条件の前に残り時間を検証する。空メッセージは即 return、ログ待ちは `docker logs` / `container logs` の再取得で過去分を失わない。
- 0036 / 0037 / 0038 で HTTP / healthcheck / exit の待機戦略が揃う前提で、条件の合成規則を本 issue が引き受ける。

## 問題

- 環境変数から待機時間を取る API がなく、CI が待機時間を外部注入する upstream の使い方を再現できない。
- 未設定・不正値（非数値、負値、表現範囲外）の扱いが未定義のままだと、実装者ごとに「エラー」と「無視」が分かれる。
- 複数 conditions の途中失敗時に後続条件を実行するかどうか、deadline をどう共有するかが文書化されていない。
- 空ログ条件の扱いが upstream の「空メッセージは常にマッチ」と同じ意味論であることを固定するテストがない。
- ログ待ちの再 poll が発行済みログを取りこぼさない条件（同一コンテナの全量再取得、deadline 内）を明文化する必要がある。

## 目標

- `WaitFor::millis_in_env_var(name)` 相当を追加し、未設定・不正値は `Nothing`（待機しない）として扱う。upstream 準拠。
- 複数 conditions は順序どおりに評価し、最初のエラーで後続を実行しない。
- すべての条件が `start` の共有 deadline を消費し、合計が startup timeout を超えない。
- 空のログメッセージ条件は即時成功になる。
- ログ待ちは deadline 内で再取得を続け、発行済みログを取りこぼさない。ストリーミング経路（0040 / 0013）への移行余地を壊さない。
- 既存の `WaitFor::millis` / ログ待ち / 複数条件の回帰がない。

## 対象外

- 各待機戦略の本体実装（0036 HTTP、0037 healthcheck、0038 exit）。
- ログの継続配信 API（0040）と Docker ログストリーム（0013）。
- 環境変数以外の設定外部化（設定ファイル、CLI オプション）。
- 新しい待機種別の追加。

## 提案する方針

- `image.mbt` に `WaitFor::millis_in_env_var(name : String) -> WaitFor` を追加する。実装は `@env.get_env_var(name)` で値を読み、`@string.parse_int64` または `parse_uint64` で数値化し、成功かつ非負なら `Millis`、それ以外（未設定、空、数値でない、負値、範囲外）は `Nothing` を返す。upstream は `millis_in_env_var` の呼び出し時点で環境変数を読むため、同じタイミングにする。
- 判定ロジックは純関数（例: `wait_millis_from_env_value(value : String?) -> Int?`）へ切り出し、環境に依存せず wbtest で網羅する。純関数名は実装詳細として変更可。
- 複数 conditions の処理は現行の配列順ループを維持する。各条件の前に `startup_remaining_ms(deadline)` を検証し、期限切れなら後続を実行せず失敗する。途中のエラーはそのまま呼び出し側へ返し、後続を実行しない。
- 空メッセージのログ条件は現行の `guard message != "" else { return }` を維持し、upstream の「空パターンは常にマッチ扱い」と同じ意味論であることを wbtest で固定する。
- ログ再 poll の意味論: CLI adapter は毎回 `logs` 全量を取得するため、deadline 内で再取得する限り過去分を失わない。終端（コンテナ終了）で早期に打ち切らない現行設計を維持し、打ち切りの判断は「death ではなく deadline」にする。将来 0013 / 0040 のストリーミング経路へ差し替える場合も、この保証（発行済みログを失わない）を満たすことを条件にする。
- `Millis` の負値・正規化規則は既存の検証（負値は fail）を維持し、env var 由来の不正値は fail ではなく `Nothing` に倒す（upstream 準拠の非対称であることを doc に明記）。

## 受け入れ条件

- [x] Given `MCT_WAIT_MS=125` のような環境変数, when `millis_in_env_var` で条件を作る, then 125 ms の `Millis` 条件になる。
- [x] Given 環境変数が未設定, when 条件を作る, then `Nothing` になり、wait 時間と deadline を消費しない。
- [x] Given 不正値（空文字、数字以外、負値、表現範囲外）, when 条件を作る, then `Nothing` になり、エラーにはならない（upstream 準拠）。
- [x] Given 3 つの conditions の 2 番目がエラー, when wait する, then 3 番目は実行されず、2 番目のエラーが呼び出し側へ返る。
- [x] Given 合計が startup timeout を超える conditions, when wait する, then 期限超過で失敗し、超過分を sleep しない（既存動作の維持）。
- [x] Given 空メッセージのログ条件, when wait する, then 即時成功する（既存動作の維持）。
- [x] 既存の `WaitFor::millis` / `WaitFor::message_on_*` の挙動に回帰がない。(205/205 pass)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 純関数へ切り出した env 値判定（未設定、空、数値以外、負値、範囲外、正常値、前後空白の扱いは実装時に upstream と同じ parse 規則へ合わせる）と、conditions 順序・途中失敗・deadline 消費を短い実時間 sleep と経過時間の上限 assertion で確認する（既存 `runtime_wbtest.mbt` の形式）。
  - 実環境変数の読取は、テストプロセスの環境を汚さない方法（subprocess fixture など)を実装時に確定する。API 名は実装時に確認したものだけを記録する。
- Linux Docker 実機（CI の Docker ジョブ）: ログ待ちと対になる条件（例: `WaitFor::millis(0)` とログメッセージ）を組み合わせ、再 poll が発行済みログを取りこぼさないことを確認する。
- Apple Silicon 実機: 同一の smoke ケースが Apple CLI の `container logs` 再取得でも成立することを確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 の実機受入時に併せて実施する。
- テスト用コンテナは固有 name に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- 未設定を「待機なしの成功」に倒す仕様は設定漏れを隠し得る。upstream 互換として明示し、利用側はログで気付けるように doc と例を整備する。
- env var 名の typo が失敗にならない。純関数テストとドキュメントで補い、必要ならデバッグログを検討する（実装時に判断）。
- ログ再取得のコストはログ量に比例する。deadline と 250 ms の既存間隔を維持し、大量ログのケースは 0013 / 0040 のストリーミングで解決する将来整合を注記に残す。
- conditions の途中失敗で、失敗条件の診断情報が不足しがち。どの条件で失敗したかをエラーに含める（実装時に形式を確定）。
- ロールバック: 追加 API と意味論の固定が中心で、既存条件の実行フローを変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] WaitFor::millis_in_env_var と複数 ready conditions の順序・失敗意味論を追加

## 注記

- upstream の対応物: [src/core/wait/mod.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/mod.rs)（`millis_in_env_var`、条件ループ）、[src/core/wait/log_strategy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/wait/log_strategy.rs)（空メッセージ即成功、EOF 後の猶予）。
- 関連: 0036 / 0037 / 0038（各戦略）、0040（ストリーミング配信）、0005（readiness 回帰テスト）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Readiness 行。
- 証跡要件: 各条件の待機時間と deadline 消費、途中失敗時の実行有無をログに残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装記録 (完了時追記)

- `WaitFor::millis_in_env_var(name)`: 呼び出し時点で `@env.get_env_var` を読み、未設定/不正値は `Nothing`(エラーにしない — upstream 準拠)。判定は純関数 `wait_millis_from_env_value` に切り出し(非負の 10 進数のみ受理、空白・符号・範囲外を reject、Int32 上限チェック)。
- 複数 conditions: 配列順評価・最初のエラーで停止・共有 deadline 消費は既存動作を維持。条件失敗時は `ready condition {i} failed: ...` と index を診断に含める(typed エラーは透過)。
- 空メッセージは `wait_for_log_until` 入口で即 return — wbtest で固定(removed container でも poll されないことを証明)。
- wbtest 4 件(env parse 全分岐/順序・中断/index 付きエラー/空メッセージ即時成功)。
- 実機 Docker / Apple での smoke ケース: **未実行**(CI/物理 Mac 待ち)。
