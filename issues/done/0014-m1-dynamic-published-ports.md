# [P0 / M1] Docker の動的 host port を IPv4/IPv6 inspect で解決

Status: doing
Model: SWE-2 Max
Created: 2026-10-16
Updated: 2026-11-04
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

起動後に `GET /containers/{id}/json` の `NetworkSettings.Ports` を解析し、`with_exposed_port`（host port 0）で割り当てられた実ポートを protocol 別に解決する。IPv4 と IPv6 を別アクセサで公開し、未公開・未割当は 0 を返さず明示エラーにする。

## 背景

- `image.mbt` の `with_exposed_port` は host port 0 の `PortMapping` を追加でき、Docker ではエフェメラル公開を要求できる。しかし `runtime.mbt` の `Container::get_host_port_ipv4` は起動時に snapshot した `mappings` のうち `host_port != 0` のものしか返さず、動的割当では「dynamic port inspection is pending」で失敗する。IPv6 のアクセサは存在しない。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、本 issue は 0011 の inspect 基盤の上に port 解決を載せる。
- upstream の `src/core/ports.rs` は `Ports` に IPv4 用と IPv6 用の BTreeMap を持ち、`map_to_host_port_ipv4` / `map_to_host_port_ipv6` で参照する。`src/core/client/docker_client.rs` の `parse_ports` は `NetworkSettings.Ports` を読み、`src/core/containers/async_container.rs` の `get_host_port_ipv4` / `get_host_port_ipv6` は未登録時に `Error::PortNotExposed { id, port }` を返す。

## 問題

- 動的公開したポートの実割当を取得する経路がなく、`host=0` の公開は事実上使えない（`smoke` も固定 port 前提）。
- IPv6 binding を返すアクセサがなく、Docker が返す `::` 側の binding を観測できない。
- 「container port は公開されているが host 側が未割当（binding が null / 空配列）」「そもそも公開指定されていない」の区別がなく、どちらも同じエラーになるか、失敗理由が分からない。
- protocol（tcp/udp/sctp）ごとの複数 mapping を同一 container port 番号で取り違える余地がある（`same_port` は protocol も比較するが、inspect 解析は未実装）。

## 目標

- inspect の `NetworkSettings.Ports` から `"80/tcp"` 形式のキーを protocol 付きで解析し、binding 配列の `HostIp` / `HostPort` を IPv4 と IPv6 に振り分けて保持する。
- `Container::get_host_port_ipv4(port)` を拡張し、host port 0 の mapping は起動後の inspect から実ポートを解決して返す。
- `Container::get_host_port_ipv6(port)` を追加し、IPv6 binding の実ポートを返す。
- 未公開（キーなし）と未割当（binding が null または空）を区別した明示エラーにし、port 0 を正常値として返さない。

## 対象外

- create request の `PortBindings` 送信側は 0010。network 情報（bridge IP）は 0015。HTTP/readiness のポート選択は 0036。
- inspect 自体の transport と not found 分類は 0011 と 0017。エラー型の公開体系は 0049。
- Apple Container XPC の port mapping は M2 の 0030。Apple の動的公開（host 0）対応は本 issue の対象外。
- 実際の host 到達性の受入（Apple の host TCP 転送）は 0003、Linux 直結 E2E の総合受入は 0020。

## 提案する方針

- `ports.mbt` に inspect 由来の mapping を保持する内部型（例: IPv4 / IPv6 の 2 つのマップ）と解析関数を追加する。公開名・置き場所は実装詳細として変更可。
  - キーは `<number>/<protocol>` に分割し、protocol が tcp/udp/sctp 以外の entry は upstream と同じく読み飛ばす。数値に変換できないキー・`HostPort` が数値でない binding も読み飛ばす（寛容動作を fixture で固定）。
  - binding の `HostIp` を見て、IPv4 リテラルは IPv4 マップ、IPv6 リテラルは IPv6 マップへ入れる。upstream の Linux 経路は `HostIp` を見ずに IPv4 マップへ入れる実装なので、MoonBit 側の振り分け規則は実機 fixture で固定する。値は `HostPort` を Int として保持する。
  - `NetworkSettings` / `Ports` が欠落・null の場合は空マップを返し、アクセサ側で未公開エラーにする。
- アクセサ（`runtime.mbt`）:
  - `Container::get_host_port_ipv4`: まず snapshot の `mappings` に `host_port != 0` の一致があればそれを返す（既存の決定的動作を維持）。なければ inspect で解決する。ポート取得のたびに daemon へ問い合わせないよう、解決結果をコンテナ内にキャッシュしてよい。
  - `Container::get_host_port_ipv6`: inspect の IPv6 マップからのみ解決する。固定 mapping の snapshot は IPv4 前提のため使わない。
  - 未公開は「container が port を公開していない」、未割当は「公開はされているが host port が割り当てられていない」とメッセージで区別し、いずれも 0 を返さずエラーにする。公開エラー型の表現は 0049 と整合させる。
  - inspect が not found を返した場合は port エラーではなく 0017 の container not found 分類を返す。
- 起動直後の割当競合: create 直後や停止直後は `Ports` が null のことがあるため、未割当エラーとし、成功を偽装しない。

## 受け入れ条件

- [ ] Given `with_exposed_port` で起動したコンテナ, when `get_host_port_ipv4` を呼ぶ, then 0 以外の実割当ポートが返り、そのポートへの TCP 接続が成功する。**未実行**（実 daemon 不在 → 0020/CI。mock daemon で inspect→IPv4/IPv6 解決を検証済み、TCP 接続は未実行）
- [x] Given `80/tcp` と `80/udp` を別々に公開したコンテナ, when それぞれを問い合わせる, then protocol ごとに独立した正しい host ポートが返る（取り違えない）。(fixture で `80/tcp`/`80/udp` 独立解決を固定)
- [x] Given 公開していない container port, when アクセサを呼ぶ, then 未公開であることを示すエラーになる。(`not exposed` メッセージで固定)
- [x] Given 公開済みだが binding が null の container port, when アクセサを呼ぶ, then 未割当であることを示すエラーになり、未公開と区別できる。(`exposed` キー集合で区別 — `no IPv4/IPv6 host port assigned`)
- [x] Given IPv4 と IPv6 の両 binding を持つ fixture, when 解析する, then IPv4 アクセサと IPv6 アクセサがそれぞれの `HostPort` を返す。(`HostIp` に `:` を含む → IPv6 マップ、それ以外（`0.0.0.0`/空）→ IPv4 マップ — upstream は全て IPv4 扱いだった点を文書化し fixture で固定)
- [x] Given IPv6 binding のみを持つ fixture, when IPv4 アクセサを呼ぶ, then 未公開エラーになり、IPv6 アクセサは値を返す。
- [x] Given 不正なキーや数値でない `HostPort` を含む fixture, when 解析する, then その entry を読み飛ばし、他の entry は正しく解決する（クラッシュしない）。(`bad/key` プロトコル、`HostPort:"0"` スキップを固定)
- [x] Given 動的割当（host 0）のコンテナ, when アクセサが返す値, then 0 は決して返らない。(`HostPort` 0/非数値は解析時にスキップ、アクセサは未割当エラー)
- [x] 既存の固定 port の `get_host_port_ipv4` 動作（snapshot 優先）と `smoke` の port 検証が回帰しない。(snapshot→inspect 優先順位を維持、131 tests PASS)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 実機から取得した inspect JSON fixture を使い、IPv4/IPv6 binding、protocol 重複（`80/tcp` と `80/udp`）、null binding、欠落 `NetworkSettings`、不正キー・不正 `HostPort` の解析を検証する。
- Linux Docker 実機（CI の Docker ジョブ）: 0010/0011 の daemon-backed test に続けて、host port 0 で公開した Alpine を起動し、`get_host_port_ipv4` の値で TCP 接続を確認する。`docker port` の出力と突き合わせて fixture を更新する。証跡を残す。
- IPv6 の実到達確認は CI ランナーの IPv6 設定と daemon の dual binding（create 側の `HostIp` 指定に依存）に左右されるため、fixture 検証を主とし、実機で確認できない場合は理由付きで「未実行」と記録する。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外（XPC は 0030）。固定 port の Apple 検証は既存 `smoke_apple` / 0003 の範囲とする。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- create 側（0010）が upstream と同じ `HostIp: 0.0.0.0` を送る場合、IPv6 binding が生まれず `get_host_port_ipv6` は常に未公開エラーになり得る。実機の inspect 出力で確認し、必要なら 0010 の `HostIp` 方針を別途見直す（本 issue の解析は両 binding を扱えるようにしておく）。
- inspect を毎回呼ぶとレイテンシが増える。解決結果のキャッシュと、固定 mapping の snapshot 優先で呼び出しを減らす。
- 寛容な読み飛ばしで設定ミスを隠す。読み飛ばし件数や内容をデバッグ時に確認できるようにし、wbtest で固定する。
- 未公開と未割当のメッセージ区別が保たれないと利用者が復旧できない。エラー文面を fixture 化して 0049 の分類と突き合わせる。
- ロールバック: 変更は inspect 解析とアクセサに限定し、port 公開要求の argv/JSON（0010）と既存 snapshot 契約を変えない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker inspect の NetworkSettings.Ports から動的 host port を IPv4/IPv6 別に解決する

## 注記

- upstream 参照: [src/core/ports.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs)（`Ports`、`map_to_host_port_ipv4`、`map_to_host_port_ipv6`、`ContainerPort::from_str`）、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`parse_ports`）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`get_host_port_ipv4` / `get_host_port_ipv6`、`Error::PortNotExposed`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の「Dynamic host port / bridge IP: Fixed host ports only」を本 issue で解消する。
- 証跡: 起動コンテナの inspect JSON（`NetworkSettings.Ports`）、アクセサの戻り値、TCP 接続結果、`docker port` の出力を残す。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`ports.mbt` に `ResolvedPorts`（`exposed` キー集合 + IPv4/IPv6 マップ）と寛容な `parse`（非 tcp/udp/sctp・非数値・port 0・不正 binding は読み飛ばし）を追加。IPv4/IPv6 振り分けは `HostIp` の `:` 含有で行い、upstream の「全て IPv4」実装との差異を文書化。`ContainerInspect` に `ports` フィールド追加（`NetworkSettings.Ports` 解析）。API 経路に `DockerClient::get_host_port_ipv4/ipv6`、CLI 経路に `Container::get_host_port_ipv4`（snapshot 優先 + `docker inspect` フォールバック、`resolved_ports` キャッシュ）と `get_host_port_ipv6` を追加。公開シグネチャ変更: `get_host_port_ipv4` は `fn`→`async fn`（inspect が非同期のため）。未公開/未割当はメッセージで区別（型の体系化は 0049）。moon check --deny-warn PASS、131 tests PASS。実 daemon E2E は未実行（CI）。
- 2026-11-04: start
