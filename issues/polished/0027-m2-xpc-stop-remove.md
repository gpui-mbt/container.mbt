# [P0 / M2] Apple XPC stop/remove と idempotent cleanup

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC の stop（grace 付き SIGTERM / 即時 SIGKILL）と remove を実装し、冪等性・他コンテナへの非干渉・timeout 後の追跡を実機で固定する。

## 背景

- 現行 CLI adapter の stop は `docker stop` / `container stop`、rm は `rm --force` / `delete --force` を実行し、`Container.removed` フラグで二重 rm を抑止するだけである。XPC では stop / delete の意味論が公開されていない。
- upstream の `stop` は [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs) にあり、`containerStop` へ `id` と `stopOptions`（`{"signal": "SIGTERM"|"SIGKILL", "timeoutInSeconds": N}`）を送る。既定は SIGTERM + 30 秒、`Some(0)` は即時 SIGKILL、負値は SIGTERM + `i32::MAX` 秒（無限待ちに近い）、正値は SIGTERM + 指定秒。apiserver は停止完了（グレース経過 + SIGKILL）を待って reply を返すため、XPC 送信タイムアウトは「グレース + 30 秒」とし、最低 60 秒、最大 24 時間で飽和させる（`xpc_timeout_for_grace`）。
- upstream は存在しないコンテナへの stop / delete を冪等成功として扱う（not found 相当の XPC エラーを成功に丸める。文字列プレフィクスで判定している）。
- remove は `containerDelete` に `id` と `forceDelete`（bool）を送る。upstream の `rm` / `rm_blocking` は常に `force=true` である。停止済みコンテナの状態は `containerList`（id filter）から `state == "running"` で判定する（`container_state`）。
- `ContainerAsync::stop_with_timeout` は SIGTERM を無視するコンテナで最大 24 時間ブロックした後に XPC タイムアウトを返し得ると明記している。Drop の 5 秒削除（`DROP_REMOVE_TIMEOUT`）や `keep` との関係は M3 の 0042 が定義する。
- 0026 が create / start と rollback を提供する。0029 が logs FD、0041 が stop と exit code の語義を扱う。

## 問題

- CLI delete と XPC の停止・削除の意味論が同一と仮定できず、grace と hard kill の違いを公開 API で表現できない。
- 繰返し stop / rm の安全性（既停止・既削除・他者による削除）が未定義である。
- timeout 後に停止処理が継続しているかもしれない状態をどう追跡するかが未定義である。

## 目標

- grace（SIGTERM + timeout）と hard kill（SIGKILL）を API で扱える。
- stop / rm 後の状態確認（inspect）とエラー分類を定義する。
- 繰返し stop / rm が安全（冪等）で、他コンテナへの操作が及ばない。
- timeout 後の状態を追跡できる（状態確認とエラーの区別）。

## 対象外

- graceful stop と exit code の語義統一（0041）。
- Drop / `keep` / watchdog の cleanup 契約（0042）。
- logs FD の停止と所有権（0029）。
- 実機受入の完走（0032）。
- Linux 側の stop / rm（0011）。

## 提案する方針

- 新規 `xpc_lifecycle.mbt`（新規、または `xpc_container.mbt` へ集約。実装詳細として変更可）に stop / remove を実装する。
  1. `stop_with_timeout(timeout)`:
     - なし → SIGTERM + 30 秒（upstream の既定）。
     - `0` → SIGKILL + 0（即時）。
     - 負値 → SIGTERM + `i32::MAX` 秒（Apple container が負値を扱えないための錯覚回避。upstream 準拠）。
     - 正値 → SIGTERM + 指定秒。
     - XPC 送信タイムアウトは「グレース + 30 秒、最低 60 秒、最大 24 時間」とする。
  2. not found: stop / remove とも冪等成功として扱う。判定は 0024 のエラー型で行い、文字列プレフィクスへの依存を持ち込まない。
  3. `remove(force)`: `containerDelete` に `forceDelete` を送る。公開 `rm()` 相当は `force=true` を既定にする（upstream 準拠）。既削除 ID への再 rm は成功。
  4. inspect: stop 後は container list の `state` で非 running を確認する。rm 後は対象 ID の一覧が空になることを確認し、空は `ContainerNotFound` として扱う（upstream の `with_first_container` と同じ）。`Container.removed` フラグと XPC の実状態が矛盾しないようにする。
  5. timeout の追跡: 送信タイムアウトで戻った場合は「停止未完了の可能性」を表すエラーとして区別し、呼出し側が再 inspect できるようにする。追跡のための状態確認 API（container list / state）を公開または明示的な内部関数として提供する。エラー本文に ID と経過時間を含める。
  6. 他コンテナ非干渉: 操作は create 時に確定した ID だけに作用する。label 検索や一覧走査による削除を行わない。テストで並置コンテナが無傷であることを確認する。
  7. CLI adapter の `removed` フラグ相当の二重削除抑止は XPC 側でも維持し、最終的な真実は inspect に置く。
- 状態遷移のテスト容易性のため、timeout 計算・not found 判定・stopOptions JSON 生成を純関数にする。

## 受け入れ条件

- [ ] Given 起動中の所有コンテナ, when 既定の stop を実行する, then 停止し、container list で running が false になる。
- [ ] Given 起動中の所有コンテナ, when `stop_with_timeout(0)` を実行する, then 即時 SIGKILL 相当で停止する。
- [ ] Given SIGTERM を無視する fixture, when 短い timeout で stop する, then グレース経過後に停止が完了するか、未完了を表す timeout エラーが返り、その後の状態確認で running の有無を追跡できる。
- [ ] Given 停止済みまたは削除済みの ID, when stop / rm を繰り返す, then 成功し（冪等）、他のコンテナは変更されない。
- [ ] Given stop → rm の完了, when 対象 ID を inspect する, then not found になる。
- [ ] Given 並置した無関係なコンテナ, when 対象コンテナを stop / rm する, then 無関係なコンテナは running のまま残る。
- [ ] Given 他プロセスが先に削除した後の rm, when 実行する, then 成功として扱われる（not found 冪等）。
- [ ] Given 600 秒超の grace, when stop する, then XPC 送信タイムアウトが「グレース + 30 秒」に伸び、60 秒で誤タイムアウトしない（上限で飽和する）。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - unit / wbtest（実機不要）: stopOptions JSON、timeout 計算の 3 分岐と上限飽和、not found の冪等判定、rm の force 既定、二重削除抑止と inspect の整合。
- 物理 Apple Silicon 実機: stop（既定 / 0 / 短 timeout）、SIGTERM 無視 fixture、stop → rm → not found、並置コンテナの非干渉。GitHub の macOS runner では代替しない。このブランチでは「未実行」。
- 証跡: 状態遷移（running → stopped → deleted）、stop の所要時間、timeout 時のエラー本文とその後の inspect 結果、Apple container version。
- 破壊対象は所有 label を持つテストコンテナに限定する（`issues/README.md` 運用ルール 5）。

## リスク

- SIGTERM 無視時の SIGKILL 挙動が fixture の再現性に依存する。実機で確認できない場合は「未実行」と記録し、PASS と混同しない。
- 大きい grace で呼出が長時間ブロックする。上限（24 時間）をテスト可能な形にし、ドキュメントに明記する。
- not found の判定が version 差で崩れる。文字列プレフィクスに依存せず、0024 の型付き分類を使う。
- 二重削除抑止と実状態の不整合。真実を inspect に置き、フラグは最適化に留める。
- ロールバック: 追加 API は 0026 で作成した所有 ID にのみ作用し、既存 CLI 経路を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] macOS で Apple Container XPC による stop（graceful / hard kill）と冪等な remove を追加する

## 注記

- 参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（`stop` / `remove_blocking` / `xpc_timeout_for_grace` / `container_state` / not found の扱い）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`stop_with_timeout` / `rm` / `rm_blocking` / SIGTERM 無視時の注意）。
- 証跡: stop / delete の route ログ、状態遷移、timeout 時の追跡結果。
- 保守者の判断に委ねる点: 公開 `stop` の引数形（既存 `stop()` を維持しつつ timeout をどう受けるか）は 0041 の語義統一と整合させて決める。
- 関連: 0026（create / start）、0029（logs FD の停止）、0041（graceful stop と exit code）、0042（Drop / keep 契約）、0032（受入）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
