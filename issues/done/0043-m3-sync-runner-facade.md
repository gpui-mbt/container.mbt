# [P2 / M3] SyncRunner と同期 Container 操作の安全な設計

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-18
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M3
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

MoonBit 環境で同期 façade（SyncRunner / 同期 Container 操作）を実装できるかを安全性の判定基準で評価し、実装する場合は再入を fail-fast する同期 API を追加し、実装しない場合はその理由と代替手段を文書化する。

## 背景

- upstream は [src/runners/sync_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/sync_runner.rs) と [src/core/containers/sync_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/sync_container.rs) で blocking API を提供する。共有 tokio Runtime を Weak 参照で保持し、async コンテキスト内から呼ばれた場合は `Handle::try_current()` で検出して別スレッドで `block_on` し、Runtime 外では直接 `block_on` する。
- upstream はコールバック内から同期 API を呼ぶと共有 Runtime への再入で deadlock し得るため、再入を検出して即エラー（fail-fast）にしている（[src/core/logs/consumer.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/logs/consumer.rs) の制約記述）。
- MoonBit 版は `moonbitlang/async@0.22.4` の async 専用で、同期 façade は存在しない。「[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の全 API が async」という前提でテストが書かれている。
- MoonBit に `block_on` / event loop の駆動 / async コンテキスト検出に相当する API があるかは未確認であり、実装可否は調査で決まる。

## 問題

- 同期コードベースの利用者（upstream Rust からの移植者）は全呼び出しを async へ書き換える必要がある。移行ガイドがない。
- 「安全でない同期 wrapper」を後から思いつきで追加すると、event loop の再入や deadlock を生む危険がある。判断基準が文書化されていない。
- 実装しない選択をする場合の理由と代替（async API の利用例）を残す場所が決まっていない。

## 目標

- 判定基準に基づいて同期 façade の実装可否を決定し、決定と根拠を記録する。判定基準は (a) event loop を独立に実行できる、(b) async コンテキスト内からの呼び出しを検出できる、(c) 処理を別スレッドで実行できる、の 3 点とする。
- 実装する場合: 通常の同期呼び出しが start → exec → stop → rm の lifecycle を完走し、危険な再入（async コンテキスト内からの同期呼び出し等）は deadlock せず即エラーになる。
- 実装しない場合: 非対応の理由と async API での代替例を README または [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) に明示する。
- どちらの場合も既存 async API のシグネチャと挙動を変えない。
- 決定プロセス自体を成果物とし、後続 issue が同じ調査を繰り返さないようにする。

## 対象外

- 個々の lifecycle 操作の実装（0011 等）。本 issue は façade の設計と決定だけを扱う。
- LogConsumer の再入制約（0040）と watchdog（0042）。
- MoonBit 言語処理系や `moonbitlang/async` への変更・要望提出。
- CLI adapter の同期化（0019 の移行方針に従う）。

## 提案する方針

- 第一段階として `moonbitlang/async@0.22.4` の公開 API を調査し、(a)(b)(c) のチェックリストを埋める。(a) は「実行中の async コンテキストと独立した event loop を起動できるか」、(b) は「現在のコードが async コンテキスト内かを検出できるか」、(c) は「別スレッドで処理を実行できるか」を確認する。API 名は調査で確認したものだけを記録する。
- 3 基準すべてを満たす場合: 新規 `sync.mbt`（ファイル名は実装詳細として変更可）に同期 façade を実装する。内部で専用の event loop を持ち、既存 async 実装をラップする。async コンテキスト内からの呼び出しは検出して即エラーにする（upstream の reentry 検出に相当）。テストは同期 lifecycle の完走と再入 negative fixture の両方を持つ。
- 1 つでも満たさない場合: 同期 façade を提供しない決定を記録し、async API での代替パターン（`@async` の実行例）を README / PORTING.md に書く。決定は「未調査」ではなく「基準 (a)(b)(c) の不成立根拠」として残す。
- 決定結果と根拠は本 issue の完了時に注記または docs へ追記し、CHANGES.md の扱いを確定する。

## 受け入れ条件

- [ ] 判定基準 (a)(b)(c) のそれぞれについて、確認した API と成否が記録されている。
- [ ] 実装する場合: Given 通常のコンテキスト, when 同期 façade で start → exec → stop → rm を実行する, then async API と同等の結果が返る。
- [ ] 実装する場合: Given async タスク内, when 同期 façade を呼ぶ, then deadlock せず即エラーになる（negative fixture）。
- [ ] 実装しない場合: 非対応の理由と代替手段が README または docs/PORTING.md に記載されている。
- [ ] どちらの場合も既存 async API のシグネチャ・挙動に変更がなく、既存テストが回帰しない。
- [ ] 決定結果が本 issue または docs に記録され、後続作業者が再調査不要になっている。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 実装する場合:
  - ネイティブ同期 consumer の sample（smoke 相当）で lifecycle 完走を確認する。
  - wbtest で再入 negative fixture（async コンテキスト内からの同期呼び出しが即エラーになること）を検証する。
  - Linux Docker 実機（CI の Docker ジョブ）で同期 lifecycle を確認する。
- 実装しない場合:
  - 実行テストは追加せず、決定記録と文書更新をレビューで確認する。
- Apple Silicon 実機での同期 lifecycle は、実装する場合にのみ 0002 / 0032 の実機受入へケースを追加する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録する。
- テスト用コンテナは固有 name に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- 判定を誤って危険な block_on を導入すると hard hang になり、テストで検出しにくい。基準 (a)(b)(c) を満たさない限り実装しない保守的な判断を既定にする。
- 実装しない場合、upstream からの移植者にとって API が狭く見える。移行ガイドと async 例で補う。
- `moonbitlang/async@0.22.4` の更新で判定前提が変わる可能性。判定根拠にバージョンを記録し、更新時は再評価の契機とする（0053 の drift 追跡と連動）。
- 別スレッド実行で共有状態（Container など）の安全性を損なう設計を混入させる危険。façade は既存 async 実装の薄いラッパに限定し、状態を複製しない。
- ロールバック: façade は追加のみで、実装しない決定の場合は文書のみ。既存 API を変更しない。

## 変更履歴

`CHANGES.md` impact: 判定結果に従う。実装する場合は yes、非対応と決定した場合は no（決定記録と文書更新のみ）。

項目案（実装する場合のみ）:

- [ADD] 同期 runner facade と再入検出を追加

## 注記

- upstream の対応物: [src/runners/sync_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/sync_runner.rs)、[src/core/containers/sync_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/sync_container.rs)（`block_on_runtime`、`Handle::try_current` による再入検出、共有 Runtime の drop 対策）。
- 依存バージョン: [moon.mod](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/moon.mod) の `moonbitlang/async@0.22.4`。
- 関連: 0011（inspect 等）、0019（CLI adapter 移行方針）、0040（LogConsumer 再入制約）、0053（upstream drift）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Start / exec / stop / rm / logs 行。
- 証跡要件: 判定基準 (a)(b)(c) の調査結果（確認した API と成否）、実装する場合は同期 lifecycle と再入 negative fixture のログ、実装しない場合は文書の差分を残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

---

## 実装記録（完了: 同期 façade は提供しない）

判定基準 (a)(b)(c) を `moonbitlang/async@0.22.4` および core に対して調査した結果、**3 点すべて不成立**のため同期 façade は実装しない。

| 基準 | 調査結果 | 成否 |
|---|---|---|
| (a) 独立した event loop を起動できるか | エントリポイントは `async fn main` のみで、loop の起動はコンパイラが担う。`internal/event_loop` は module 外から import 不可。`block_on` に相当する公開 API は存在しない。`set_external_event_loop`（`external_loop_integration`）は C 側埋め込みから MoonBit の loop を駆動する逆向き API であり、MoonBit の同期コードから async 関数を呼び出す手段ではない | 不成立 |
| (b) async コンテキスト内呼び出しを検出できるか | `Coroutine::current_coroutine` は `internal/coroutine`（`internal/` パッケージは module 外から import 不可）にあり再 export されていない。upstream の `Handle::try_current()` 相当の API は公開 surface に存在しない | 不成立 |
| (c) 別スレッドで実行できるか | `moonbitlang/async` は single-threaded model（event loop は epoll/kqueue/IOCP、blocking file IO のみ内部 thread pool に委譲で公開 API ではない）。core / stdlib にスレッド生成 primitive は存在しない | 不成立 |

根拠（upstream との対応）: upstream の SyncRunner は (a) `tokio::Runtime` を `Weak` で保持して `block_on`、(b) `Handle::try_current()` で再入検出、(c) 検出時は別スレッドで `block_on`、という 3 部構成で安全を担保している。MoonBit では 3 つとも再現不能であり、安全な block_on 代替が組めないため「実装しない」が唯一の保守的判断（本 issue のリスク欄既定に一致）。

### 再評価契機

`moonbitlang/async` の更新で (a) 公開 event-loop 駆動 API、(b) coroutine context 検出 API、(c) スレッド API のいずれかが公開された場合は再評価する（0053 drift 追跡と連動）。判定基準となる upstream pin: `shiguredo/container-rs@f68ba1ff`。

### 代替手段

`async fn main` をトップレベルエントリとし、内部で async API を直接使用する。CLI ツール等で同期的に見せたい場合でも、MoonBit 側で同期ラッパを書くのではなく、`async fn main` 内で完結させる。embedded C から MoonBit を呼ぶ場合は `set_external_event_loop` を用いる（この場合も同期 MoonBit API ではなく、C 側が MoonBit event loop を駆動する構成）。

### 受け入れ条件（実装しないブランチに沿って）

- [x] 判定基準 (a)(b)(c) のそれぞれについて、確認した API と成否が記録されている。
- [x] 実装しない場合: 非対応の理由と代替手段が docs/PORTING.md に記載されている。
- [x] 既存 async API のシグネチャ・挙動に変更なし（コード変更なし、既存テスト回帰なし）。
- [x] 決定結果が本 issue と docs/PORTING.md に記録され、再調査不要。

### 変更履歴（確定）

`CHANGES.md` impact: no（決定記録と文書更新のみ、実装なし）。
