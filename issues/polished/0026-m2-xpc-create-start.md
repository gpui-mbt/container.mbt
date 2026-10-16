# [P0 / M2] Apple XPC container create/start と rollback

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: [0024](./0024-m2-xpc-protocol-contract.md), [0025](./0025-m2-xpc-image-pull.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`GenericImage` のスナップショットを XPC の container config へ変換し、create → bootstrap → start を分離して実行する。途中失敗時は作成した ID だけを rollback する。

## 背景

- 現行 MoonBit は CLI の `container run --detach` に create と start を委譲しており、ID を一括で受け取る。この構造は run 失敗時に ID を失う問題（0001）と同根で、XPC 直結では create / start を分離して ID を確定してから後続へ進む必要がある。
- upstream の macOS 起動経路（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）は次の順で進む。ID 決定（`container_name` または `c-{unique_suffix}`）→ ID 検証 → SCTP / 重複 port / kernel の検証を pull 前に実行 → descriptor 解決 / pull → image config（CMD / ENTRYPOINT）解決 → kernel 取得 → volume 解決 → config 構築 → `containerCreate` → watchdog 登録 → `containerBootstrap` → `containerStartProcess` → copy_to → logs FD 取得 → readiness。
- 失敗時は各段で作成 ID を force remove する（`rollback_remove`）。readiness 失敗時は `cleanup_on_ready_failure` が rm する（`TESTCONTAINERS_COMMAND=remove` のとき）。
- ID の制約は Apple container 1.2.0 の `nameValid` 相当で、63 文字以下、`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`（[src/core/util.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs) の `is_valid_container_id`）。不正 ID はロールバックの `containerDelete` でも同じ検証に落ちるため、pull 前に fail-fast する。
- config 構築は [src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs) の `build_config` が行う。init process（executable / arguments / environment / workingDirectory / user）、mounts、publishedPorts、labels、network（未指定は `default`）、architecture と rosetta（platform 正規化の結果）、readOnly、cpus（既定 4）、creationDate（Swift 参照日 2001-01-01 基準）、runtimeHandler 等を含み、`containerCreate` には `containerConfig` / `kernel` / `containerOptions`（`{"autoRemove":false}`）を Data として送る。bootstrap は `dynamicEnv` に `{}` を送り、start は `processIdentifier` に ID を送る。
- 0025 が pull と参照解決を提供する。0028 / 0029 / 0030 / 0031 が exec / logs / ports / mounts の詳細を引き継ぐ。

## 問題

- create と start が分離されておらず、起動途中の失敗で ID を失うと回収できない。
- Apple container の ID 制約、SCTP 非対応、host port 0 非対応、重複 port の検出が CLI 任せで、XPC 直結では事前検証が存在しない。
- image config の CMD / ENTRYPOINT とユーザー指定の優先規則、env の畳み込み規則が未実装である。
- 起動中に `GenericImage` を変更した場合のスナップショット規則が mappings / ready_conditions にしかない。

## 目標

- Apple CLI を起動せずに XPC 直結で create / start できる。
- create → bootstrap → start → readiness を分離し、readiness 失敗でも所有 ID を rollback する。
- 同名衝突・不正 config・非対応設定を副作用（pull / create）の前にエラーにする。
- 起動後の構成が builder の後続変更に影響されない。
- 起動失敗後にテスト用コンテナが残らない。

## 対象外

- image pull と manifest 選択（0025）。
- exec（0028）、logs FD（0029）、ports / network の inspect（0030）、mount の詳細互換と copy（0031）。
- stop / rm の意味論（0027）。
- CLI adapter の修正（M0）。
- 自動 reaper / Drop の回収契約（0042）。

## 提案する方針

- 新規 `xpc_container.mbt`（新規、実装詳細として変更可）に config 構築と create / start の順序制御を実装する。
  1. 起動前に `GenericImage` のスナップショット（command / entrypoint / env / labels / mappings / mounts / working_dir / user / network / platform / readonly_rootfs）を取る。以降の構築はスナップショットだけを読む（既存の `start` が mappings / ready_conditions を copy している方針を全項目へ拡張する）。
  2. preflight（副作用前）: ID 検証（name 指定時と自動生成時。63 文字・`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`）、SCTP port の拒否、重複 container port の拒否、host port 0 の事前割当（upstream の `allocate_unique_free_host_port` と同じ思想。空きポートを確保し、割当済みと衝突しないよう再試行し、上限到達はエラー）、非対応 platform の正規化、healthcheck の明示拒否（macOS では恒久的に対象外）、exit wait の明示拒否（0038 で実装予定）。mount のうち実体解決が必要な volume は 0031 の完了まで明示エラーにする（黙って無視しない）。
  3. 同名衝突の事前検出: 対象 ID を id filter とした container list を行い、存在すれば create 前にエラーにする（0011 の Linux 側と同じ思想。create 時のエラーも同名衝突として分類する）。
  4. kernel の取得: `getDefaultKernel` で取得する（upstream と同じく systemPlatform は arm64 固定。amd64 ゲストでも arm64 カーネルを使う）。取得失敗は pull / create の前にエラー。
  5. image config の解決（0025 の解決結果から CMD / ENTRYPOINT を取得し、ユーザー指定との優先規則を適用する。upstream の `effective_command` と同じ規則: ユーザー指定があれば優先、未指定なら image config、どちらも無ければエラー。entrypoint の単一空文字列はクリア扱い）。
  6. config 構築: upstream `build_config` と同じフィールド構成で JSON を組み立てる。今回扱う範囲は init process、environment（後勝ちの畳み込み）、labels（`container-mbt.owned` 系の所有 label を含む。0001 の規則を共有）、ports（固定 host port と事前割当）、network、architecture / rosetta、readOnly、cpus、creationDate（Swift 参照日基準）、containerOptions（`autoRemove:false`）。mounts は 0031 の完了まで上記のとおり限定する。
  7. create → bootstrap → start: `containerCreate`（`containerConfig` / `kernel` / `containerOptions`）→ `containerBootstrap`（`dynamicEnv` = `{}`）→ `containerStartProcess`（`processIdentifier` = ID）。
  8. rollback: create 成功後の各段に失敗ハンドラを置き、作成 ID を `forceDelete` で削除する（not found は冪等成功）。rollback は await して完了を保証し、rollback の失敗で元エラーを上書きしない（0001 と同じ方針。失敗理由は元エラーへ付記する）。
  9. readiness: 既存の deadline 方式（`startup_remaining_ms` / `wait_ready_until`）を踏襲し、XPC では「create / start まで」と「readiness」を関数として分離する。readiness のうち log message 系は 0029 の FD 契約を前提とするため本 issue の受入対象外とし、delay と状態確認（container list の running）までを対象にする。log message 系は 0029 完了後に結合して 0032 で検証する。
- テスト可能にするため、config JSON の生成と preflight を純関数へ寄せ、実機依存部分（route 送信）を薄くする。

## 受け入れ条件

- [ ] Given 物理 Apple Silicon と取得済み alpine:3.20, when XPC 直結で start する, then コンテナが running になり、実行中にライブラリが Apple CLI のプロセスを起動していない（証跡: プロセス一覧とログ）。
- [ ] Given 同名のコンテナが既存, when `with_container_name` で同名を指定して start する, then create 前にエラーになり、既存コンテナは変更されない。
- [ ] Given 不正な name（64 文字以上、許可外文字）や重複 port、SCTP port, when start する, then pull / create の前にエラーになる。
- [ ] Given bootstrap または start が失敗する設定, when start が失敗する, then create 済み ID が force delete され、同一 ID が残っていない。
- [ ] Given rollback の delete が失敗する, when エラーが返る, then 元の失敗理由が主となり、rollback 失敗が付記される。
- [ ] Given 起動成功後に builder へ `with_mapped_port` / `with_env_var` を追加する, when 起動済みコンテナの構成を確認する, then 構成は起動時のスナップショットから変わらない。
- [ ] Given 未対応設定（未解決の volume mount、healthcheck wait など）, when start する, then 明示エラーになり、黙って無視されない。
- [ ] Given 実行ログ, when route の送信順を確認する, then create → bootstrap → start の順で、pull 前に preflight が完了している。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - unit / wbtest（実機不要）: config JSON の生成（fixture との比較）、env の畳み込み、CMD / ENTRYPOINT の優先規則、ID 生成と検証、preflight の順序（pull / create が呼ばれないこと）、port 事前割当と重複拒否、rollback の判断ロジック（純部分）。
- 物理 Apple Silicon 実機: create / start の成功、同名衝突、失敗注入（不正 config 相当）と残存ゼロの確認。GitHub の macOS runner では代替しない。このブランチでは「未実行」。
- 証跡: route ログ、container list の前後、エラー本文、Apple container version。
- 破壊対象は所有 label を持つテストコンテナに限定する（`issues/README.md` 運用ルール 5）。

## リスク

- config JSON が Apple container の Swift デコードに合わない（creationDate の基準、enum の形）。fixture と実機の往復で固定し、形状不一致は明示エラーにする（0024）。
- ID 制約の見落としで create と rollback の両方が失敗する。pull 前に検証し、ロールバックが使えないケースを残さない。
- rollback 忘れ。create 直後から各段に失敗ハンドラを置き、unit で段ごとの rollback を確認する。
- 待ち時間の増大。preflight と kernel 取得を pull 後に行うと無駄が増えるため、順序を upstream に合わせて副作用の前に寄せる。
- readiness の log 系を本 issue に含めると 0029 と重複する。分離を関数境界で明確にする。
- ロールバック: 追加モジュールは 0027 以降から使われるまで既定経路に接続されない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] macOS で Apple Container XPC によるコンテナ create/start を追加し、起動途中の失敗では作成 ID だけを rollback する

## 注記

- 参照: [src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)（config 構築と制約）、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)（順序・rollback・readiness）、[src/core/util.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs)（ID 制約）。
- 証跡: 実機の create / bootstrap / start の route ログ、container list 前後、エラー本文。
- 保守者の判断に委ねる点: `getDefaultKernel` の systemPlatform を arm64 固定のままにするか（upstream 準拠）は、amd64 ゲスト検証の結果で見直す。
- 関連: 0001（rollback 方針の源流）、0025（pull）、0028 / 0029 / 0030 / 0031（後続）、0032（受入）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
