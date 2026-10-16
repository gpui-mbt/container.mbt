# [P0 / M3] 所有 container の Drop/keep/watchdog cleanup 契約

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M3
Depends on: [0021](./0021-m1-linux-process-crash-recovery.md), [0032](./0032-m2-apple-native-xpc-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

所有 scope に限定した自動クリーンアップ契約を実装する。正常経路のスコープ終了 cleanup、`TESTCONTAINERS_COMMAND=keep` による自動削除の抑止、プロセス異常終了時の watchdog 回収を、所有証明できる ID だけを対象に提供する。

## 背景

- 現行は明示 `rm()` のみで自動削除がない。[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Compatibility and safety constraints も "Explicit `rm` is mandatory for now. No automatic cleanup contract is implemented." と明記している。
- upstream の [src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) は Drop で `DROP_REMOVE_TIMEOUT` = 5 秒の best-effort 削除を行う。失敗はログにのみ記録し、呼び出し側へは返さない。`TESTCONTAINERS_COMMAND=keep` のときは Drop が削除しないが、明示 `rm` は keep でも削除する（ゲートは非対称）。
- upstream の [src/watchdog.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs) は外部 reaper プロセス方式を採る。起動したコンテナ ID を pipe 経由で reaper（`/bin/sh`）に登録し、reaper は stdin の EOF（親プロセスの死。シグナル種別を問わず起きる）を検知したら全 ID を削除する。登録は create 直後に行い、keep 指定時は登録しない（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）。spawn / respawn の失敗上限は `MAX_SPAWN_FAILURES` = 3。行分割を壊す不適合な ID は登録しない。
- MoonBit 側には Drop に相当するデストラクタ trait が見つかっていない（core の該当 API を確認できていない）ため、スコープ付きの明示 API で代替する。
- `@env.get_env_var` は既存依存で利用できる（[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) は `@process` / `@shell` / `@async` を利用済み）。

## 問題

- 利用者が `rm()` を忘れるとコンテナが残る。プロセスが SIGKILL / クラッシュした場合は明示 rm が実行されず、孤児がホストに蓄積する。
- keep の意味論（自動削除のみ抑止し、明示 rm は有効）が存在しない。
- 回収対象を所有コンテナに限定する仕組みがなく、誤ってユーザー所有コンテナを削除する危険を排除できない。
- 監視プロセスの多重起動・残留を防ぐ契約が未定義。

## 目標

- スコープ終了時に所有コンテナだけを best-effort で自動削除する API を提供する。回収失敗で元の処理結果を壊さない。
- `TESTCONTAINERS_COMMAND=keep` の完全一致で自動削除のみを抑止する。明示 `rm()` は keep でも有効のまま。
- プロセス異常終了（SIGKILL 含む）でも、所有を証明できる ID のみを watchdog が回収する。keep 時は watchdog 登録もしない。
- watchdog は 1 プロセス 1 reaper とし、プロセス終了で必ず終了して残留しない。spawn 失敗が上限に達したら警告して watchdog を無効化し、無限 respawn しない。
- 所有証明（起動時に発行する run ID / label。0001 の仕組みと整合）が得られない ID は削除しない。
- 既存の明示 `rm()` の冪等性と意味論に回帰がない。

## 対象外

- ID を受け取る前の run 失敗時の回収（0001。M0 の CLI adapter 修正）。
- Linux でのプロセスクラッシュ後の残存検出と限定回収そのもの（0021。本 issue は新規起動分の watchdog 契約を定める）。
- Apple XPC native 受入（0032）と XPC の rm 実装（0027）。
- readiness 失敗時の rollback（既存 `errdefer`。回帰は 0005）。
- グローバルなゴミ回収（他の起動要求やユーザー作成コンテナを探して消すこと）。

## 提案する方針

- スコープ API: [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) に `with_container(image, runtime, body)` 相当のヘルパーを追加する（API 名は実装詳細として変更可）。正常終了・エラー・キャンセルのいずれの経路でも、body 実行後に `rm()` を best-effort で呼ぶ。cleanup の予算は upstream の `DROP_REMOVE_TIMEOUT` = 5 秒相当の有界値とし、既存 `rm()` の 30 秒 timeout を使う内部実装とは別に短縮版を用意する。cleanup 失敗は元の結果を上書きせず、警告として記録する。
- keep 判定: `TESTCONTAINERS_COMMAND` を `@env.get_env_var` で読み、`"keep"` との完全一致だけを真とする純関数を追加する（大文字小文字・前後空白・部分一致は偽。upstream の完全一致と同じ）。この関数はスコープ cleanup と watchdog 登録の自動削除のみをゲートする。`Container::rm()` は影響を受けない。
- watchdog: 別プロセス（reaper）を spawn し、所有コンテナ ID を 1 行ずつ stdin へ渡す。親プロセスの終了で stdin が EOF になり、reaper が登録 ID を削除する。MoonBit の `@process` / `@shell` で子プロセスの stdin を開いたまま保持できるかを実装時に確認する。保持できない場合は watchdog を無効化した上でその事実を文書化し、0001 / 0021 の回収に一本化する（契約の偽装はしない）。
- 登録対象: 改行・空白を含むなど行分割を壊す ID は登録しない。所有を証明できる run ID / label と対応付け、`rm` は対象 ID に限定する。
- 失敗上限: reaper の spawn / respawn 失敗が上限（upstream は 3 回）に達したら、警告を遷移時に 1 回だけ出して watchdog を無効化する。既存 reaper への write 失敗（外部 kill 等）は上限を消費しない。
- 停止順序: 正常終了時はスコープ cleanup が先に削除し、reaper の削除は無害に失敗する（upstream と同じ）。reaper は EOF で自然終了し、プロセス一覧に残らないことをテストで確認する。

## 受け入れ条件

- [ ] Given `with_container` 相当のスコープ API で起動し正常終了, when keep 未設定, then 所有コンテナは削除され、明示 `rm()` と重複しても冪等である。
- [ ] Given `TESTCONTAINERS_COMMAND=keep`, when スコープ終了, then コンテナは残り、その後の明示 `rm()` は成功して削除される。
- [ ] Given keep 未設定でプロセスを SIGKILL, when watchdog が動いている, then 所有 ID のコンテナだけが回収され、無関係なコンテナとユーザー所有コンテナは残る。
- [ ] Given `TESTCONTAINERS_COMMAND=keep` で SIGKILL, when プロセス死, then watchdog は登録しておらず、コンテナは残る。
- [ ] Given reaper の spawn が上限まで失敗, when 登録を試みる, then 警告が一度だけ出て watchdog が無効化され、処理は継続する。
- [ ] Given スコープ cleanup が失敗（例: 既に削除済み）, when body が正常終了, then 元の結果がそのまま返り、失敗は警告に留まる。
- [ ] 既存の明示 `rm()` / stop / smoke に回帰がない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: keep 判定（完全一致のみ真、大文字・空白・部分一致は偽）、ID 登録可否（改行・空白を含む ID の拒否）、cleanup 予算のクランプ、スコープ API のエラー経路での cleanup 呼び出しを fake runtime で確認する。
- Linux Docker 実機（CI の Docker ジョブ）で確認する。
  - 正常終了 cleanup と keep 残置を確認し、前後で `docker ps -a` を証跡に残す。
  - SIGKILL 回収: 子プロセス fixture でコンテナを起動し、SIGKILL 後に所有 ID だけが消え、事前作成した無関係コンテナが残ることを確認する。
  - reaper 残留の否定: テスト後にプロセス一覧で reaper が残っていないことを確認する（確認手段は実装時に確定）。
- Apple Silicon 実機: Apple CLI 経路でも同等の cleanup / keep / kill 回収を確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0002 / 0032 の実機受入時に併せて実施する。
- テストは所有 ID / 固有 label に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- 誤削除が最悪の事故になる。所有証明が取れない場合は削除しない方針を実装とテストの両方で固定する。
- reaper プロセスの残留・多重起動。1 プロセス 1 reaper と EOF 終了をテストで確認し、spawn 失敗上限で無限 respawn を防ぐ。
- keep の非対称（自動削除のみ抑止）を誤解すると事故になる。doc と CHANGES に明記し、明示 rm が有効であることをテストで固定する。
- MoonBit に Drop 相当がないため、スコープ API の外で起動したコンテナは従来どおり明示 rm が必要。この制約を doc に残す。
- stdin を保持したままの子プロセス spawn が MoonBit のプロセス API で実現できない可能性。実現できない場合は watchdog 非対応を明示し、回収は 0001 / 0021 に委ねる。
- ロールバック: 新規 API と環境変数ゲートの追加が中心で、既存挙動を変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] 所有コンテナのスコープ cleanup・TESTCONTAINERS_COMMAND=keep・watchdog 回収を追加

## 注記

- upstream の対応物: [src/watchdog.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs)、[src/core/env.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/env.rs)、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs) の Drop、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs) の登録ゲート。
- 現行の明示 rm 方針を記す [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の記述は、本 issue の完了時に更新する。
- 関連: 0001（run 失敗時の回収）、0021（プロセスクラッシュ検出）、0027（XPC stop/remove）、0032（Apple native E2E）、0005（回帰テスト）。
- 証跡要件: keep / kill / cleanup の各ケースで `docker ps -a` または `container list --all` の前後、reaper の警告、回収対象 ID をログまたは artifact に残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
