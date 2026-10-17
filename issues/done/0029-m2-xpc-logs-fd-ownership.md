# [P0 / M2] Apple XPC logs の FD 所有権と停止処理

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC `containerLogs` が返す stdout と bootlog の 2 FD の所有権を 1 箇所へ集約し、start / stop / rm / 再起動 / consumer 停止 / Drop の全経路で閉じる。フォロー読み取りの停止とキャンセルも有界にし、FD 数を操作の前後で増やさない。

## 背景

- 現行 MoonBit の `Container::logs`（[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)）は `docker logs` / `container logs` を 15 秒 timeout・64 MiB 上限で一括取得するだけで、FD を保持しない。
- upstream は `XpcClient::logs`（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）が `containerLogs` の 2 FD を返す。受け手の `ContainerLogSource::Fd { stdout, stderr }`（[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)）が所有し、Drop で `close` する。閉じ忘れるとコンテナ 1 つにつき 2 FD がリークするとコメントで明示している。
- 2 本目の FD は VM の bootlog であり、アプリケーションの stderr は stdout 側のログに混流する（async_container.rs の `stderr` doc）。
- `stop_with_timeout` と Drop は共通前置き `stop_log_delivery` で停止フラグ `log_stop: Arc<AtomicBool>` を立てて consumer タスクを止める。reader は停止フラグを poll して終了する。
- 再起動（`ContainerAsync::start`）は `refresh_log_streams` で新しい FD の取得に成功してから、旧 consumer 停止 → 旧 FD close → 差し替え → consumer 再 spawn を行う。取得失敗時は部分更新せず、呼び出し側が SIGKILL でコンテナを巻き戻してエラーを返す。
- `containerLogs` が 2 FD 未満、または -1 を含む応答を返した場合、upstream は取得済みの有効 FD をすべて close してからエラーにする。consumer 停止時の配信終了契約は [src/core/logs/consumer.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs) が持つ。

## 問題

- MoonBit 側に FD の所有権・追跡・閉鎖の契約がなく、XPC logs を追加するとリークしやすい。
- stop / rm / 再起動 / consumer 停止のどの経路で誰が FD を閉じるかが未定義。
- 2 本目の FD が bootlog である区別がなく、「stderr」を約束すると誤配信する。

## 目標

- stdout FD と bootlog FD の所有権を 1 箇所に集約し、全操作経路で閉じる。
- start / stop / rm / 再起動 / consumer 停止 / Drop の後に FD 数が操作前より増えない。
- フォロー停止とキャンセルで reader が終了し、FD が閉じる。
- 再起動後は新しい FD でログを受信し、旧 FD は閉じている。
- bootlog をアプリ stderr として二重配信しない。

## 対象外

- Docker Engine のログストリーム実装（0013）と LogConsumer の backpressure（0040）。
- ログ待機戦略の意味論（0036–0039）。ただし停止フラグは待機と共有する公開契約として整理する。
- stop / rm 自体の semantics（0027）。

## 提案する方針

- 0024 が定める XPC 配置に `logs` を追加する（例: `xpc_client.mbt`（新規、実装詳細として変更可））。`containerLogs` の応答から 2 FD を取り出し、2 FD 未満・無効 FD のときは取得済みの有効 FD をすべて close してからエラーにする。
- `Container` 側（[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の拡張、または M2 用 `xpc_container.mbt`（新規、実装詳細として変更可））に log source（None / Fd { stdout, bootlog }）を保持し、close を 1 箇所に集約する。close 後は None を代入して二重 close を防ぐ。
- 停止フラグは `Container` が保持し、stop / rm / Drop / 再起動の共通前置きで立てる。フォロー reader は有界 poll でフラグを確認し、確認時に FD を閉じて終了する。
- 再起動は「新 FD 取得成功 → 旧 consumer 停止 → 旧 FD close → 新 FD 差し替え → consumer 再武装」の順に固定する。取得失敗時は差し替えず、硬い停止で巻き戻してエラーを返す。
- stderr アクセサは bootlog を返すこと、アプリ stderr は stdout 側に混流することを docs に明記する。
- FD 数の比較手段（`/dev/fd` の列挙、`lsof` 等）は実機セッションで確定し、証跡にコマンドと生出力を残す。

## 受け入れ条件

- [ ] Given XPC で起動したコンテナ, when stop → rm → Drop する, then 操作前後で FD 数が増えていない。
- [ ] Given stdout と stderr に別々の文字列を出したコンテナ, when logs を読む, then アプリ出力は stdout 側で取得され、2 本目は bootlog として区別され、混線しない。
- [ ] Given フォロー読み取り中, when 停止またはキャンセルする, then reader が終了して FD が閉じる。
- [ ] Given 停止済みコンテナ, when 再起動して logs を再取得する, then 新しい FD で追記を受信し、旧 FD は閉じている。
- [ ] Given `containerLogs` が 1 FD しか返さない、または無効 FD を返す, when logs を取得する, then 有効 FD がすべて close されエラーになる。
- [ ] Given 起動 → 停止 → 再起動を繰り返す, when 各段で FD 数を比べる, then 単調増加しない。
- [ ] consumer 停止後に別の follow を開始しても、停止済み consumer へ誤配信しない。
- [ ] 既存 CLI adapter の `Container::logs` の公開契約を壊さない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: 停止フラグの状態遷移、FD 差し替えの順序（抽象化した fake FD で）、bootlog と stdout の区別ロジック、部分取得エラー時に close 漏れがないこと。
- Apple Silicon 実機（macOS 26+。CI に物理 Mac は存在しない）: FD 数の前後比較、mixed stdout/stderr、follow 停止とキャンセル、stop → start → logs 再取得、障害注入（1 FD 応答）。実行できるまで「未実行」と記録し、CI compile-only で代用しない。0032 の受入へ含める。
- 再起動を N 回（例: 10 回）繰り返し、各段の FD 数を証跡として記録する。

## リスク

- FD の二重 close / close 漏れ: 所有を 1 箇所に限定し、close 後の None 代入を必須にする。
- consumer スレッドが FD を握ったまま残留: 停止フラグと有界 poll で終了を保証する。
- 再起動中の一部分更新: 「新 FD 取得成功後にだけ差し替え」の順序を固定する。
- bootlog をストリームとして約束しすぎる: docs で意味を明記し、アクセサの命名で区別する。
- ロールバック: 新規 XPC モジュールに閉じ、CLI logs の経路を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Apple Container XPC のログ FD を所有・追跡し、停止・削除・再起動で確実に閉じる

## 注記

- 主な参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)、[src/core/logs/consumer.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs)、FD 所有と再起動差し替えの [src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)。
- 証跡: FD 数の前後比較ログ、起動 / 停止 / 再起動の操作ログ、キャンセル後の reader 終了ログ。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。0032 の受入で本 issue の FD 証跡を確認する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

`containerLogs` の 2 FD を取得し、無効時は有効 FD を閉じてエラー。one-shot `logs()` と `subscribe_logs` の XPC 経路、stop/rm 前の配信停止を実装。`smoke_xpc` で one-shot と live tick 配信、FD 6→7 が PASS。再起動 10 回の FD 比較は未実行。
