# [P1 / M1] Linux でプロセスクラッシュ後の残存検出と限定回収

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0020](./0020-m1-linux-native-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

SIGKILL 等で `errdefer` が動かなかった場合に、所有 label と所有者の生存確認から孤児コンテナを検出し、所有が証明できるものだけを回収する仕組みを定義して実機で固定する。

## 背景

- 現行 `runtime.mbt` の `start` は readiness 失敗時の rollback を `errdefer` に依存する。プロセスが SIGKILL されるとこの処理は走らない（README の "A CLI launch that times out before its container ID is known can still leave a runtime-owned container behind" と同根の問題）。
- upstream は `watchdog` feature（macOS のみ、[src/watchdog.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs)）で external reaper 方式を採る。reaper プロセスが stdin からコンテナ ID を読み、stdin の EOF（親プロセスの死。シグナル種別を問わず必ず起きる）を検出して `container rm --force "$id"` を実行する。ID は `is_valid_container_id`（63 文字以下、`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`）で検証してから登録し、spawn 失敗 3 回で watchdog を無効化する（`MAX_SPAWN_FAILURES`、warn は 1 回）。reaper は別プロセスグループで起動して Ctrl-C の巻き添えを防ぎ、登録は create 直後（bootstrap / start / copy 中のクラッシュに備える）に行う。`TESTCONTAINERS_COMMAND=keep` 相当のときは登録しない。詳細は 0042 で契約化する。
- Linux 側には同等の仕組みがなく、M1 の Docker 直結経路でもクラッシュ残存が起こり得る。
- 0001 が CLI run 失敗時（ID 取得前）の orphan 回収を扱う。本 issue はプロセス死亡後に別実行から検出する経路を扱う。

## 問題

- SIGKILL / SEGV 後の残存テストコンテナを次回実行が検出できず、`--name` 衝突やランナーの資源消費を起こす。
- 無条件の「古いコンテナを全部削除」はユーザー所有や他プロセス所有のコンテナを破壊する。
- 残存の所有を証明する手段（label 規約、所有者の生存確認）が未定義である。

## 目標

- SIGKILL 後の残存を所有 label で検出できる。
- 回収は所有が証明できるもの（自分の label 値 + 所有者プロセスの死亡）だけに限定する。
- 外部（ユーザー・他プロセス）作成コンテナは削除しない。
- 回収を再実行しても誤削除しない。
- 除外理由と削除失敗理由が診断として残る。
- Linux Docker Engine 直結（CLI 非依存）で動作する。

## 対象外

- 自動 reaper の発火タイミング・`keep` 契約・Drop 連携の確定（0042。本 issue は検出と限定回収のプリミティブまで）。
- CLI run が ID を返す前の失敗に対する同一起動要求内の回収（0001）。
- macOS XPC 側の回収（0032 / 0042）。
- Docker ボリューム / ネットワークの回収（本 issue はコンテナのみ）。
- 他利用者の Docker daemon を横断する掃除（自 label の範囲を出ない）。

## 提案する方針

1. 所有 label を 1 箇所で定義する（新規 `recovery.mbt`（新規、実装詳細として変更可）か、0001 の label 生成を共通モジュールへ移す）。key は 0001 と同じ `container-mbt.owned`、値はプロセス単位の owner-id。
2. owner-id は upstream `core/util.rs` の `unique_suffix` と同じ思想（pid + ナノ秒時刻 + プロセス内カウンタ）で生成し、name もこの owner と対応付ける（0001 の `container-mbt-<run-id>` 規則と矛盾しない形にする）。
3. 所有者の生存確認は lock file の flock で行う。owner は起動時に `$XDG_RUNTIME_DIR/container-mbt/<owner-id>.lock` 相当（fallback の場所と権限は実装時に確定、0700 のディレクトリ）を作成して flock を保持し続ける。プロセス死亡時はシグナル種別を問わずカーネルがロックを解放するため、PID 再利用による誤判定が起きない。ロックが取れない owner-id は生存中として回収対象外にする。
4. 検出: Docker Engine API の container list（all 相当）で label `container-mbt.owned` 付きコンテナを列挙する。各コンテナについて (a) label 値が正しい形式で、対応する lock が取得できる（= 所有者不存在）なら回収候補、(b) label 欠落・不正値・lock 取得済み（生存中）は候補にしない（診断ログに理由を出す）。
5. 回収: 候補の ID だけを 0011 の削除 API（force 可）で削除する。1 回の実行に上限件数と期限を設け、途中失敗は集約して返す。ID を探索して消すのでなく、列挙で得た ID へ明示的に作用する。
6. 呼出し口は明示 API（例: `recover_orphaned_containers()`。名前は実装詳細）とし、`start` の既定経路へ自動挿入しない。ハーネス（0020 の smoke など）の開始時に呼ぶ。自動 sweep の採否は 0042 で決める。
7. 診断: 「回収した ID 数」「候補から除外した ID と理由（label 不一致 / 生存中 / list 失敗）」「削除失敗と HTTP status」をログと戻り値の要約に残す。
8. クライアントは直結 transport（0006–0011）を使い、docker CLI に依存しない（M1 の CLI 非依存方針、0019）。
9. 検証 fixture: 子プロセス側 entry point（`smoke_crash`（新規、実装詳細）など）がコンテナを start して待機し、親（bash step または MoonBit の別プロセス）が PID を取得して `kill -9` した後、回収 API を実行する。MoonBit から自バイナリの再実行が容易でない場合は、CI step の bash で子の起動と kill を orchestrate し、検証は MoonBit 側で行う。

## 受け入れ条件

- [ ] Given 子プロセスがコンテナを start した状態, when 子を SIGKILL する, then 回収 API はその owner のコンテナを検出する。**未実行**（実 daemon なし。CI が `smoke_crash` を `kill -9` してから `smoke_linux` を実行 — recover step が label+lock で検出。mock では dead-owner 行が DELETE まで到達することを検証）
- [ ] Given 回収 API の実行完了, when container list を確認する, then 死んだ owner のコンテナは 0 件で、外部で作成した無関係なコンテナは存在したまま。**未実行**（CI の `docker ps -a` grep + foreign inspect assert；mock で無 label/他人 owner は skip されることを検証）
- [ ] Given 同じ回収 API を 2 回目に実行する, when 回収済みである, then 削除は 0 件で成功する（誤削除なし）。**mock で検証**（404 delete は冪等成功として removed に計上 — 再実行で対象は既に不在）。実 daemon 再確認は CI 未実行。
- [x] Given 生存中の別 owner がコンテナを保持している, when 死んだ owner の回収を実行する, then 生存 owner のコンテナは削除されない。(wbtest: テストが live owner の lock file を保持 → skipped("still alive")、DELETE されない)
- [x] Given label のないコンテナ, when 回収を実行する, then 候補にも削除にも含まれず、除外理由が診断ログに残る。(wbtest: `container-mbt.owned` 欠落行は skipped("no container-mbt.owned label") — server filter を当てにしない client 側再検査)
- [x] Given label 値が不正な形式のコンテナ, when 回収を実行する, then 削除せず、不正値であることが診断に残る。(wbtest: `garbage!!` → skipped("malformed owner label"); `valid_owner_id` の形式テスト群)
- [x] Given 削除 API が失敗する状況（他プロセスが先に削除した等）, when 回収を実行する, then 失敗理由が集約され、成功した件数と区別できる。(wbtest: 500 → failed 集約、404 → 冪等で removed 計上、`summary()` が三者を区別)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: owner-id / name の一意性と形式、label の組み立て、lock の生存判定（取得できる / できない）、候補選定が純関数として検証できること、不正 label の除外。
- Linux Docker 実機（CI の Docker ジョブ）: クラッシュ注入 fixture を bash orchestration で実行し、kill 前後の container list と回収ログを証跡に残す。0020 完了後に実行し、それまでは「未実行」。
- 破壊対象は `container-mbt.owned` label を持つコンテナだけに限定する（`issues/README.md` 運用ルール 5）。
- Apple Silicon 実機: 対象外（XPC 側の回収は 0042 と 0032）。本 issue では実機記録しない。
- docker daemon が使えない環境では「未実行」と明記し、擬似テストだけで完了にしない。

## リスク

- 回収範囲が広すぎてユーザー所有を壊す。label 一致と lock 解放の二重条件にし、label が読めない・一致しない場合は絶対に削除しない。
- lock file の場所や権限が環境で揺れる。0700 の専用ディレクトリを第一候補にし、fallback を実装時に確定して docs に残す。
- PID / 時刻の衝突で owner-id が重複する。pid + ナノ秒 + カウンタ（upstream 方式）で実用上排除する。
- rootless Docker では socket と権限が異なる。回収は socket 接続エラーを明示エラーとして返し、部分削除の成否をログに残す（互換境界は 0022 に記録）。
- 回収 API が既定経路へ混入する。明示 API として実装し、`start` へ自動挿入しない（0042 で判断）。
- ロールバック: 追加する検出・回収は opt-in の明示呼出しに閉じる。呼ばなければ既存挙動は変わらない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Linux で SIGKILL 後に残った所有コンテナを label と所有者の生存確認で検出して限定回収する recovery ヘルパを追加する

## 注記

- 参照: [src/watchdog.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs)（reaper 方式・ID 検証・process group 分離・spawn 失敗上限）、[src/core/util.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs)（`unique_suffix` / `is_valid_container_id`）、[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)。
- 0001 と label / name の生成規則を共有し、二重定義しない。
- upstream の reaper は `container rm --force` を使うが、本移植の Linux 直結では CLI を使わない。reaper 自体の Linux 実装（常駐プロセス方式の採否）は 0042 で判断する。
- 証跡: kill -9 前後の container list、回収ログ（除外理由を含む）、削除失敗の HTTP status。
- 関連: 0020 の fixture を拡張する。0042 が自動回収・Drop・`keep` の契約を定義する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`container-mbt.owned` の値を attempt の run-id から**プロセス owner-id**（`p<pid>-t<16hex>`、pid+時刻+nonce で一意）へ変更し、CLI・直結両経路で同一 label を付与（0001 の同一 run 検出は inspect の Name フィールド経由で従来どおり成立）。lock 方式: `ensure_owner_lock()` が `$XDG_RUNTIME_DIR/container-mbt/`（無ければ `/tmp/container-mbt-<uid>`、0700）に `owner-<id>.lock` を作成し flock(LOCK_EX|LOCK_NB) をプロセス寿命分保持 — シグナル種別を問わずカーネルが解放。`recovery.mbt` 新設: `GET /containers/json?all=true&filters={"label":["container-mbt.owned"]}` で列挙し、label 形式検証→owner lock probe→`remove_container(force)`。`RecoveryReport`（removed/skipped/failed 三者分離）を返す明示 API — `start` へ自動挿入なし。`smoke_crash` fixture（start 後待機→CI が kill -9）と `smoke_linux` 冒頭の recover 呼出しで実機 fixture を配備。新 FFI: `getpid`/`getuid`/`flock_try`。moon check --deny-warn PASS、156 tests PASS。CHANGES.md は未存在のため項目案のみ記録。実 daemon クラッシュ注入は CI 初回実行で採証（未実行）。
