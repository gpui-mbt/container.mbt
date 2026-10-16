# [P1 / M3] privileged・capability・shm・init 等を移植

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`with_privileged` / `with_cap_add` / `with_cap_drop` / `with_shm_size` / `with_init` 相当のリソース・セキュリティ設定を `GenericImage` へ追加し、対応 adapter では実コンテナへ反映、未対応 adapter では副作用前に明示エラーにする。

## 背景

- 現行 [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `GenericImage` は cmd / entrypoint / env / label / mount / port / `readonly_rootfs` までで、リソース・capability 設定を持たない。[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` も `--read-only` までしか組み立てない。
- upstream `ImageExt`（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)）は `with_privileged(bool)`（114 行付近）、`with_cap_add` / `with_cap_drop`（121–123 行付近。呼び出しごとに push して蓄積）、`with_shm_size(u64)`（125 行付近。後勝ちで上書き）、`with_init()`（171 行付近）を公開する。
- upstream の Docker 経路は `HostConfig` の `Privileged` / `Init` / `CapAdd` / `CapDrop` / `ShmSize` に載せる（[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) 1178–1236 行付近）。macOS 経路は `containerCreate` の `capAdd` / `capDrop` / `shmSize` / `useInit` に載せ、`privileged` は `capAdd` を `["ALL"]` に正規化して個別 capability 指定を上書きする（[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs) 229–236 行付近、1861 行付近のテスト）。
- 関連: 0044 が mount 詳細、0045 が hostname / ExtraHost / network を扱う。本 issue はリソース・セキュリティ option に限定する。

## 問題

- 現行 API に該当 option が無く、upstream 利用者の privileged / capability / shm / init 設定を表現できない。
- 既定値の契約がない。privileged 未指定で true になる、未対応 option が黙って無視される、といった silent 挙動を防ぐ検証が未実装。
- 負の shm サイズや空の capability 名が image pull / container create の副作用まで到達し得る。
- Apple CLI adapter（`container run`）が同等設定をどこまで受け付けるか未確認で、黙って無視する危険がある。

## 目標

- 型付き option API が追加され、既存 API を壊さない。
- Docker adapter で値が実コンテナへ反映され、inspect で確認できる。
- 無効値は pull / create より前に拒否される。
- privileged は明示指定された場合だけ true になり、他 option から暗黙に導出されない。
- 未対応 adapter では明示エラーになり、silent ignore されない。

## 対象外

- mount の size / mode / read-only 詳細（0044）。
- hostname / ExtraHost / network（0045）。
- Engine API 直結の create JSON 構築そのもの（0010）。本 issue は option 追加と adapter ごとの反映・検証を担い、実機受入は 0020 / 0032 に従う。
- Apple XPC の `with_kernel` / `with_ssh` / `with_masked_paths` / `with_readonly_paths`（0047）。本 issue は XPC の `capAdd` / `capDrop` / `shmSize` / `useInit` と privileged 正規化までに限定する。

## 提案する方針

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `GenericImage` にフィールドを追加する（内部名は実装詳細として変更可）。
  - `privileged : Bool` 既定 false。
  - `cap_add` / `cap_drop : Array[String]` 既定空。
  - `shm_size_bytes` は upstream の `u64` を表現できる型（`Int64?` 等、実装時に選定）。負値を受ける型にはしない。
  - `init : Bool` 既定 false。
- API は upstream の意味論に揃える。
  - `with_privileged(enabled)` は後勝ち。false へ戻せる（upstream image_ext.rs 347–353）。
  - `with_cap_add` / `with_cap_drop` は呼び出しごとに蓄積（upstream 363–379）。
  - `with_shm_size(bytes)` は後勝ちで上書き。負値は設定時に fail。
  - `with_init()` は true にする。
- `commands.mbt` の `build_run_args` で Docker CLI 向けに `--privileged` / `--cap-add` / `--cap-drop` / `--shm-size` / `--init` を組み立てる。フラグ書式は実装時に `docker run --help` で確認し、upstream の `HostConfig` と同じ内容（バイト数など）を渡す。
- 検証は run 引数構築の先頭・副作用の前に集約する。capability 名の文法（空文字・空白・制御文字の拒否）は Docker の受け付ける文法を確認して決定する。shm サイズは負値と型の範囲超過を fail にする。
- privileged=true のときは upstream macOS と同じ「全 capability 相当」の正規化を明文化する。Docker では `--privileged` の意味を変えないことを inspect で確認し、XPC 配線後は upstream と同じ `capAdd: ["ALL"]` になることを確認する。
- Apple CLI adapter は同等フラグの有無を実機（Apple container）で確認する。確認できるまでは未対応 option を起動前の明示エラーにする。XPC 経路（0026 完了後）は `containerCreate` の `capAdd` / `capDrop` / `shmSize` / `useInit` へ配線し、CLI で再現できないものは 0019 の capability gate に従って拒否する。

## 受け入れ条件

- [ ] Given shm サイズに負値, when `build_run_args` / `start` する, then pull / create より前に定義したエラーで失敗する。
- [ ] Given `privileged = false` と `cap_add` のみ, when Docker で start して inspect する, then `Privileged` は false のまま `CapAdd` だけが設定される。
- [ ] Given `privileged = true` と `cap_add` の同時指定, when Docker で start して inspect する, then `Privileged` が true になり、XPC 経路では upstream と同じ `capAdd: ["ALL"]` 正規化になる（XPC 配線後に検証）。
- [ ] Given `with_init()`, when Docker で start して inspect する, then `Init` が true。
- [ ] Given Apple CLI adapter で未対応の option, when `start` する, then 副作用の前に明示エラーになる（黙って無視されない）。
- [ ] Given privileged を一度も指定しない, when start する, then コンテナは privileged にならない。
- [ ] Given 既存 API のみを使う呼び出し, when ビルド・実行する, then 挙動が変わらない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: API の蓄積 / 後勝ち、負値拒否、`build_run_args` のフラグ組み立て（`--privileged` / `--cap-add` / `--cap-drop` / `--shm-size` / `--init`）を検証する。
- Docker 実機（CI の docker-e2e ジョブ）で `alpine:3.20` を cap / shm / init 付きで start し、`docker inspect` の `HostConfig` を照合する。生成 name prefix に限定して削除し、ユーザー所有コンテナを触らない。
- Apple 実機は物理 Mac が必要なため、実行できない間は「未実行」と理由を記録し、0047 の実機確認と併せて実施する。
- 擬似テストだけで実機 E2E を代替して完了にしない。

## リスク

- privileged の追加でテスト用コンテナでも権限が上がる。既定 false のままにし、fixture で意図的に使う場合のみ明示して、ユーザー所有リソースへ影響する操作を行わない。
- Apple CLI のフラグ差異で二重実装になる。共通 option 層と adapter ごとの capability gate を分離し、0019 の方針に従って段階的に解消する。
- shm サイズの型選定を誤ると overflow で巨大値が渡る。受付時の負値拒否と上限を 1 箇所に固定し、テストで回帰を防ぐ。
- ロールバック: 新規 option と引数組み立ての追加に限定し、既存呼び出しの契約を変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] `with_privileged` / `with_cap_add` / `with_cap_drop` / `with_shm_size` / `with_init` 相当のリソース・セキュリティ設定を追加する

## 注記

- 参照: [src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の "Networking / platform / permissions" 行。0004（副作用前の明示拒否）と 0019（capability gate）の方針に従う。
- 証跡として `docker inspect` の `HostConfig` 抜粋と start 前の検証エラーをログまたは artifact に残す（0052 の CI 方針と整合）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
