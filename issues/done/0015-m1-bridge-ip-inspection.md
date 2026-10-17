# [P1 / M1] Container bridge IP と network 情報を正規化

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

inspect の `NetworkSettings.Networks` を解析し、コンテナの bridge IP を取得するアクセサを実装する。複数 network 接続時の選択規則を定め、network 未接続と IP 未割当を区別した明示エラーにする。

## 背景

- 現行 M0 にはコンテナの IP アドレスを取得する API がなく、`runtime.mbt` の `Container` は ID、runtime、port mapping、removed のみを保持する。inspect 基盤自体もない。
- M1 は Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、本 issue は 0011 の inspect の上に network 情報の正規化を載せる。
- upstream の `src/core/client/docker_client.rs` の `bridge_ip_address` は `NetworkSettings.Networks` の先頭ネットワークの `IPAddress` を取り、`std::net::IpAddr` として返す。ネットワーク名のハードコードはせず、`IPAddress` が空文字（host network 等）や `Networks` が空・欠落の場合はエラーにする。`src/core/containers/async_container.rs` の `get_bridge_ip_address` がこれを公開する。upstream コメントによると object の「先頭」はキーのアルファベット順で決まる。

## 問題

- コンテナの IP アドレスを取得する手段がなく、ホストから `exec` 以外の経路でコンテナへ到達できない。
- 複数 network に接続した場合の選択規則が未定義。network 名への依存や non-determinism があると、環境によって違う IP を返してテストが不安定になる。
- 「network に接続していない」「接続しているが IP が空（host network 等）」の区別がなく、空文字列や 0 を正常値として扱う余地がある。
- IPv6 アドレスが返る network の扱い（parse と検証）が未定義。

## 目標

- inspect の `NetworkSettings.Networks` から先頭ネットワークの `IPAddress` を取得し、検証済みの IP リテラルとして返す。
- 選択規則を「キーのアルファベット順で先頭（upstream と同じ。network 名のハードコードをしない）」として明示し、fixture と実機で固定する。
- network 未接続（`Networks` 欠落・空）と IP 未割当（`IPAddress` が空文字）を区別した明示エラーにする。
- 不正な IP 文字列はエラーにし、panic させない。

## 対象外

- port mapping の解決は 0014。inspect の transport と not found 分類は 0011/0017。エラー型の公開体系は 0049。
- create request の network 指定（`NetworkingConfig`）は 0010。hostname/ExtraHost/複数 network の作成 API は 0045。
- gateway IP（upstream では macOS 専用で `ExtraHost::HostGateway` に使う）は本 issue の対象外。
- Apple XPC の port/network inspect は M2 の 0030。Linux 直結の総合 E2E は 0020。

## 提案する方針

- `docker_client.mbt`（0010 で新設。実装詳細として変更可）に inspect 結果から network 情報を取り出す解析を追加し、`runtime.mbt` の `Container` にアクセサ（例: `get_bridge_ip_address`）を追加する。
  - `NetworkSettings.Networks` を JSON object として読み、キーのアルファベット順で先頭の entry を選ぶ。upstream は「先頭」をキー順で決めると明記しているため、同じ規則を fixture で固定する。object の iteration 順が実装依存にならないよう、選択はソートまたは明示的な比較で行う。
  - entry の `IPAddress` を文字列として読み、IPv4 / IPv6 リテラルとして検証してから返す。戻り値は検証済みの文字列とする（公開型の設計は実装時に決めてよいが、空文字や未検証値を返さない）。
  - `Networks` が欠落・空 → 「network に接続されていない」エラー。`IPAddress` が欠落・空文字 → 「network はあるが IP が割り当てられていない」エラー。どちらもコンテナ ID と選択した network 名を含める。
  - 不正な IP 文字列 → 「IP アドレスとして解釈できない」エラー。
- 複数 network の選択: `docker network connect` 等で後から接続した network も含め、常にキー順先頭を選ぶ。ユーザー指定の優先規則は 0045 で扱う。
- inspect が not found を返した場合は network エラーへ丸めず、0011/0017 の container not found 分類をそのまま返す。

## 受け入れ条件

- [ ] Given 既定 bridge network で起動したコンテナ, when bridge IP を取得する, then 検証済みの IP リテラルが返り、到達可能な場合はその IP への TCP 接続が成功する。**未実行**（実 daemon 不在 → 0020/CI。mock daemon で inspect→IP 解決を検証済み、TCP 到達確認は未実行）
- [x] Given 同じコンテナを複数 network に接続する, when bridge IP を取得する, then キー順先頭の network が選ばれ、接続順や実行タイミングに依存せず結果が安定する。(fixture で bridge/zeta/alpha の混在 + 「lex 順が MoonBit の length-first `String::compare` と異なる」ケース（"zeta" vs "bridge"）を固定)
- [x] Given host network モードのコンテナ, when bridge IP を取得する, then IP 未割当として明示エラーになり、空文字列や 0.0.0.0 を返さない。(`IPAddress:""` → `no IP address assigned`、さらに `0.0.0.0`/`::` 等の unspecified literal も同エラーに丸める)
- [x] Given network に接続していないコンテナ, when bridge IP を取得する, then 未接続であることを示すエラーになり、IP 未割当エラーと区別できる。(`Networks` 欠落・空・null → `not connected to any network`)
- [x] Given IPv6 アドレスを返す network fixture, when 解析する, then IPv6 リテラルとして検証され正しく返る。(`fe80::42:1`、`::ffff:10.0.0.1` を `@socket.Addr::parse` 経由で検証)
- [x] Given 不正な IP 文字列を含む fixture, when 解析する, then panic せず明示エラーになる。(`not-an-ip`/`999.1.1.1`/`1.2.3`/`fe80::1%eth0`/`::gggg` → `not a valid IP literal`)
- [x] Given 削除済みコンテナ, when bridge IP を取得する, then container not found の分類が返る。(mock daemon 404 → `EngineError::ContainerNotFound` がそのまま伝播)
- [x] 既存の port 解決（0014）と inspect（0011）の動作が回帰しない。(139 tests PASS)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 実機から取得した inspect JSON fixture で、単一 network、複数 network（キー順の逆転を含む）、`Networks` 欠落・空、`IPAddress` 空、IPv6、不正文字列を検証する。
- Linux Docker 実機（CI の Docker ジョブ）: 0014 の daemon-backed test に続けて、既定 bridge のコンテナで IP を取得し、可能な場合はコンテナ内 listen ポート（例: `nc`）への TCP 接続で到達性を確認する。テスト専用の network を一意な名前で作成して接続し、キー順選択の安定性を確認した後、その network だけを削除する（ユーザー所有 network を削除しない。`issues/README.md` の運用ルール 5）。
- IPv6 network の実到達確認は CI ランナーの IPv6 設定に依存するため fixture 検証を主とし、実機で確認できない場合は理由付きで「未実行」と記録する。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外（XPC は 0030）。実行できない間は理由付きで「未実行」と記録する。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- network 選択規則の実装依存（object の iteration 順）で結果が揺れる。キー順を明示的に実装し、複数 network の fixture と逆順接続の実機テストで固定する。
- host network / none network で誤った IP を返す。空 `IPAddress` と未接続を個別のエラーにし、0 を返さない。
- IPv6 の表現差（zone index 等）で parse が揺れる。upstream が `IpAddr` で検証している範囲を基準にし、zone 付きは明示エラーとして fixture 化する。
- テストがユーザーの network を壊す。作成した network は一意名で後始末し、既存 network を変更・削除しない。
- ロールバック: inspect 解析とアクセサの追加に限定し、既存 API を変えない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker inspect から bridge IP と network 情報を取得するアクセサを実装する

## 注記

- upstream 参照: [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`bridge_ip_address`）、[src/core/containers/async_container.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/async_container.rs)（`get_bridge_ip_address`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の「Dynamic host port / bridge IP: Fixed host ports only」を本 issue で解消する。
- 証跡: inspect JSON（`NetworkSettings.Networks`）、アクセサの戻り値、到達性確認の結果、作成・削除したテスト network 名を残す。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`networks.mbt` に `ContainerNetworks`（name → `IPAddress` 正規化、欠落は ""）と `bridge_ip`（lexicographic キー順で先頭選択、`String::lexical_compare` を使う — MoonBit の `Compare` は length-first で upstream の `Ord` と異なる点を文書化）を追加。IP 検証は `@socket.Addr::parse`（`ip:port` 形式のため合成 port を付与）に委譲し、`%zone`・unspecified literal（`0.0.0.0`/全ゼロ IPv6）は明示拒否。`ContainerInspect` に `networks` フィールド追加。API 経路に `DockerClient::get_bridge_ip_address`、CLI 経路に `Container::get_bridge_ip_address`（`docker inspect` の先頭オブジェクトを `inspect_obj` にキャッシュし ports/networks で共有）。moon check --deny-warn PASS、139 tests PASS。実 daemon E2E・TCP 到達確認は未実行（CI/0020）。
