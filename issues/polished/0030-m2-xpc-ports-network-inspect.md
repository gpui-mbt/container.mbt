# [P1 / M2] Apple XPC port mapping・bridge IP・host gateway

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC 経路で hostPort=0 を含むポート割当（予約 → 公開 → inspect 取得）を実装し、IPv4 / IPv6 の公開ポートと bridge IP / host gateway を解決する。SCTP は pull / create の前に拒否する。

## 背景

- 現行 MoonBit は [ports.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/ports.mbt) に `ContainerPort` / `PortMapping`（host_port 0 は ephemeral の要求）を持ち、[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` が CLI の `--publish` を組み立てる。[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `get_host_port_ipv4` は固定値のみを返し、動的割当は `dynamic port inspection is pending` で失敗する。
- `build_run_args` は AppleContainer で host_port=0 を未検証として副作用前に拒否し、SCTP 公開も拒否する（README も Apple ephemeral publishing を未検証と明記）。
- upstream は `build_config`（[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)）で hostPort=0 と expose ポートに空きホストポートを事前割当する。`allocate_free_host_port` は TCP なら `TcpListener::bind(("127.0.0.1", 0))`、UDP なら `UdpSocket::bind(("127.0.0.1", 0))` で得たポートを即 release する方式で、`allocate_unique_free_host_port` が割当済み集合との衝突を再試行上限 64 回で避ける。固定ポート同士の重複は明示エラーにする。
- 公開ポートの取得は `parse_published_ports`（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）が `containerList` の `configuration.publishedPorts` から `containerPort` / `hostPort` / `proto` / `hostAddress` を読み、`hostAddress` が IPv6 なら IPv6 mapping、それ以外は IPv4 mapping に入れる。hostPort=0 / containerPort=0 のエントリは登録しない。
- bridge IP / gateway は `networks[0].ipv4Address` / `networks[0].ipv4Gateway` を CIDR 分解して返す。ネットワーク未接続は `no network attachments` エラーになる。
- `Ports`（[src/core/ports.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs)）は container_port → host_port を IPv4 / IPv6 別に保持し、未指定時のフォールバックは IPv4 優先でキー最小のポートを返す。
- upstream は SCTP を `reject_sctp_ports` で pull 前検証と `build_config` の両方で拒否する（`SCTP port publishing is not supported on Apple container`）。

## 問題

- XPC 経由のポート予約・公開・取得が未実装で、host_port=0 は Apple で明示拒否のまま。
- IPv4 / IPv6 の区別、`publishedPorts` の `hostAddress` 解釈、hostPort=0 エントリの除外が未実装。
- bridge IP / host gateway の取得がなく、`get_host_port_ipv4` は固定値しか返せない。
- SCTP 拒否が CLI 引数の組み立てに埋まっており、XPC の config 構築経路にない。

## 目標

- hostPort=0（`with_exposed_port` を含む）で有効なホストポートが予約され、取得 API が同じポートを返す。
- 予約ポートが固定指定や他の割当と重複せず、割当失敗時は pull / create より前にエラーになる。
- IPv4 / IPv6 を区別して公開ポートを解決できる。
- bridge IP / host gateway を取得でき、ネットワーク未接続は推測せず明示エラーになる。
- SCTP は pull / create の前に拒否される。

## 対象外

- Docker Engine の動的ポート inspect（0014）と bridge IP 正規化（0015）。本 issue は XPC / Apple 経路。ポートのデータモデルは両経路で共有方針とする。
- hostname / ExtraHost / network オプションの追加（0045）。本 issue は取得 API のみ。
- CLI adapter の `--publish` 挙動の変更（M0 の既存挙動は維持し、XPC 経路に限定する）。

## 提案する方針

- [ports.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/ports.mbt) に upstream の `Ports` 相当（container_port → host_port を IPv4 / IPv6 別に保持、キー最小のフォールバック、hostPort=0 エントリの除外）を追加する。`PortMapping` の host_port=0 は予約要求として扱い、実行時に確定値へ解決する。
- 0024 が定める XPC config 構築に port 変換を追加する（例: `container_cfg.mbt`（新規、実装詳細として変更可））。hostPort=0 の予約は TCP / UDP それぞれの bind(port 0) → 即 release 方式とし、割当済み集合との衝突を再試行上限付きで避ける。値と再試行上限は upstream と同じく 64 回を上限とする。固定ポート同士の重複は明示エラーにする。
- `parse_published_ports` 相当を実装し、`hostAddress` が IPv6 のときだけ IPv6 mapping に入れる。hostPort=0 / containerPort=0 は有効ポートとして返さない。
- bridge IP / gateway は `containerList` の `networks[0]` から `ipv4Address` / `ipv4Gateway` を CIDR 分解して返す。キー欠落・ネットワーク未接続は明示エラーにする。
- SCTP の拒否は XPC 経路の事前検証（pull 前と config 構築の両方）に置き、upstream と同趣旨の文言で拒否する。
- `get_host_port_ipv4` / 新規の `get_host_port_ipv6` は固定値と inspect 解決値の両方を返す。未解決時は推測値を返さずエラーにする（`dynamic port inspection is pending` の置き換え）。

## 受け入れ条件

- [ ] Given `with_exposed_port(tcp 80)` または host_port=0 の指定, when XPC で起動する, then ホスト側で listen する有効ポートが確定し、取得 API が同じ値を返す。
- [ ] Given hostPort=0 のマッピングを複数要求する, when 予約する, then 同じ予約ポートが重複して使われない（割当済み集合で担保）。
- [ ] Given 固定ポート同士の重複指定, when config を構築する, then pull / create の前にエラーになる。
- [ ] Given `hostAddress` が `::` の publishedPort, when inspect する, then IPv6 mapping として解決され、IPv4 に混入しない。
- [ ] Given daemon 応答に hostPort=0 のエントリが残る異常系, when parse する, then 到達不能な 0 を有効ポートとして返さない。
- [ ] Given ネットワーク未接続のコンテナ, when bridge IP / gateway を取得する, then 推測せず明示エラーになる。
- [ ] Given SCTP ポートを指定する, when 起動を試みる, then pull / create の前に拒否される（CLI 経路の既存拒否と同趣旨）。
- [ ] 既存の `ContainerPort` / `PortMapping` の公開契約と Docker 経路の挙動を壊さない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: `publishedPorts` JSON の parse（IPv4 / IPv6 の振り分け、hostPort=0 / containerPort=0 の除外）、割当の一意性（fake allocator）、固定ポート重複の検出、SCTP 拒否。
- Apple Silicon 実機（macOS 26+。CI に物理 Mac は存在しない）: TCP / UDP の hostPort=0 E2E とホストからの到達、IPv6 公開、bridge IP / gateway と実際の接続、SCTP 拒否を実行する。実行できるまで「未実行」と記録し、CI compile-only で代用しない。0032 の受入へ含める。
- Docker 経路の非退行は `moon test --target native` と `moon run smoke --target native`（CI の Docker ジョブ）で確認する。

## リスク

- bind → 即 release 方式は割当後に他プロセスへ奪われ得る: 事前割当であることを docs に明記し、start 失敗時は 0026 の rollback で回収する。
- IPv6 のホスト接続は環境依存: 解決 API は提供し、接続確認は実機で行い、不能なら未実行として記録する。
- CLI adapter の hostPort=0 拒否を外すと M0 受入（0002 / 0003）へ影響し得る: XPC 経路に限定し、CLI の挙動は変更しない。
- ロールバック: ports.mbt への追加と新規 config モジュールに閉じ、既存の CLI 経路を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Apple Container XPC の動的ポート割当、IPv4/IPv6 公開ポート取得、bridge IP/host gateway 取得を実装する

## 注記

- 主な参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（`parse_published_ports` / `bridge_ip_address` / `gateway_ip_address`）、[src/core/ports.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs)、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)（`allocate_unique_free_host_port` / `reject_sctp_ports`）。
- 証跡: `publishedPorts` の inspect 生出力、ホスト側 listener の確認ログ、SCTP 拒否のエラー文面。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。0032 が実機受入の窓口。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
