# [P1 / M3] hostname・ExtraHost・network を API と実行経路に追加

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`with_hostname` と `with_host`（`ExtraHost`: アドレス / `HostGateway`）を builder に追加し、Docker の `--hostname` / `--add-host` / `--network`、Apple のネットワーク経路の差分を整理する。参照ネットワークの存在確認を副作用前に行い、自動作成はしない。

## 背景

- 現行の [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) は `with_network` のみを持ち、hostname と extra hosts は表現できない。[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` は `--network` を渡す。
- upstream の [src/core/containers/request.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs) は `hostname` / `network` / `hosts: BTreeMap<String, ExtraHost>` を持ち、`ExtraHost` は `Addr(IpAddr)` と `HostGateway` の 2 形態を取る。`with_hostname` / `with_network` / `with_host` は [src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs) が提供する。
- Docker 経路は extra hosts を `{hostname}:{host}` 形式で渡す（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）。Apple XPC には extra hosts に相当する設定がなく、起動後に exec で `/etc/hosts` へ追記する。Apple の hostname は `networks[0].options.hostname` に載り、優先順位は 明示 hostname → container_name → コンテナ ID（[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)）。
- Apple CLI の `container run` には `--network`（`<name>[,mac=][,mtu=][,alias=]`）があるが、`--hostname` と `--add-host` は文書化されたフラグに見当たらない。ホスト到達は `container system dns create ... --localhost <ipv4>` の DNS 方式が文書化されている。

## 問題

- hostname を明示指定できない。upstream の優先順位（明示 → container_name → ID）を再現できない。
- `/etc/hosts` へ追加エントリを与える API がなく、host gateway（ホストを指す特別値）も使えない。
- 参照する network の存在確認がなく、未作成ネットワーク指定では run が遅く失敗する。自動作成の有無も未定義。
- Apple CLI と Docker で `--network` 周りの意味差（参照のみ / alias / host gateway）が未整理で、利用者がランタイム非互換に気付けない。

## 目標

- `with_hostname(name)` と `with_host(key, host)` を追加し、`ExtraHost` でアドレス（IPv4 / IPv6）と `HostGateway` を表現する。
- Docker 経路は `--hostname` / `--add-host` / `--network` を正しく組み立て、Apple 経路は対応可否を実測で確定する。
- 指定 network が存在しない場合は副作用前に明示エラーになる。自動作成はしない（対応範囲として文書化）。
- hostname 未指定時のフォールバック規則（明示 → container_name → ID）を定義し、既存利用者の見え方を壊さない。
- 既存 `with_network` と既存 smoke に回帰がない。

## 対象外

- ネットワークの作成・削除・DNS 設定（例: Apple の `container system dns create ... --localhost` 方式）。
- XPC の hostname / extra hosts 対応（M2。0026 の create と 0030 の network に委譲する）。
- 動的 host port と bridge IP の inspect（0014 / 0015 / 0030）。
- Mac 専用の kernel / ssh 等のオプション（0047）。
- Podman 等の互換ランタイム差異（0022。host gateway の解釈差は注記に残す）。

## 提案する方針

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) に `ExtraHost` enum（`Addr(String)` / `HostGateway`）と `with_hostname(name)` / `with_host(key, host)` を追加する。`with_host` はキー（空禁止、空白・改行・`: ` を含む形式の禁止）とアドレス形式を副作用前に検証する。IP アドレス形式の parse API は core にあるかを実装時に確認し、確認できたものだけを使う（無い場合は簡易検証に留め、その旨を記録する）。
- [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` を拡張する。Docker は `--hostname <name>`、`--add-host <key>:<addr|host-gateway>`、`--network <name>` を追加する。Apple は `container run --help` で `--hostname` / `--add-host` の有無を実装時に再確認し、無い場合は該当設定で副作用前に明示エラーにする（0004 の方針継続）。
- network preflight: 指定がある場合に `docker network inspect`（Docker）/ `container network inspect`（Apple）で存在確認する。1 回の inspect に限定し、存在しない場合は自動作成せずエラーにする。network 名の検証（空、空白、危険な文字）は副作用前に済ませる。
- hostname フォールバック: 明示 `with_hostname` がある場合のみ `--hostname` を渡す。未指定時に `container_name` を hostname に流用するかは、既存コンテナの見え方を変えるため既定では行わず、upstream の優先順位との差異を doc に明記する（実装時に最終判断）。
- Apple の host gateway: CLI に `host-gateway` 相当がないため、`ExtraHost::HostGateway` は Apple CLI 経路で副作用前に拒否する。代替手段（`container system dns create ... --localhost`）は利用者向け doc に記載し、XPC 経路での回収は 0030 に委譲する。
- `with_host` の Apple CLI 拒否は、exec 追記方式（upstream の起動後 `/etc/hosts` 追記）ではなく XPC 側の設計会話に一本化する。CLI adapter で追記する案は採用しない（副作用が起動後に及び、rollback が複雑になるため）。

## 受け入れ条件

- [ ] Given `with_hostname("myhost")`, when Docker で run する, then コンテナ内 hostname が `myhost` になる。→ 引数組み立ては wbtest で確認。**実機反映は未実行**（daemon 非搭載。CI Docker ジョブで受入）。
- [ ] Given `with_host("db", ExtraHost::Addr("10.0.0.5"))`, when Docker で run する, then コンテナ内 `/etc/hosts` に `10.0.0.5 db` が入る。→ `--add-host db:10.0.0.5` 組み立ては wbtest で確認。**実機 /etc/hosts 検証は未実行**。
- [ ] Given `ExtraHost::HostGateway`, when Docker かつ host gateway 対応環境で run する, then `host-gateway` が `--add-host` に渡り、ホスト到達を確認できる。→ `host-gateway` 文字列の emit は wbtest で確認。**ホスト到達の実機検証は未実行**（バージョン依存、0022 に記録済み方針）。
- [x] Given 存在しない network 名, when run する, then 副作用前に明示エラーになり、コンテナは作成されない。network は自動作成されない。→ `ensure_network_exists` が direct（`GET /networks/{name}`）と CLI（`network inspect`）の両経路で副作用前に 1 回だけ確認。404/非零終了 → `network does not exist`。mock socket で検証。
- [x] Given Apple CLI で未対応の設定（hostname / add-host / host gateway）, when run する, then 副作用前に明示エラーになる。→ `Setting::Hostname`/`Setting::ExtraHosts` を追加し CliApple は Rejected。
- [x] Given 既存の `with_network` 利用箇所, when 再実行する, then `--network` の引数に回帰がない。→ 全既存テスト無変更で通過。
- [x] hostname 未指定時の組み立てが既存と同一である（後方互換）。→ wbtest で `--hostname`/`--add-host` 非含有を確認。

## 実装メモ

- `ExtraHost`（`Addr(String)`/`HostGateway`）、`with_hostname`/`with_host`/`with_host_addr`/`with_host_gateway` を追加。Addr の値は空・空白のみ拒否（core に IP parser なし、コロンは IPv6 のため許容 — 簡易検証であることを記録）。
- hostname フォールバック（明示 → container_name → ID）は**採用しない**: 未指定時に `--hostname` を出すと既存コンテナの hostname が変わるため。明示指定のみ `--hostname`/`"Hostname"` を emit。upstream との差異として記録。
- direct 経路は `Hostname` トップレベル + `HostConfig.ExtraHosts`（`key:value` 文字列、`HostGateway` → `host-gateway`）。CLI 経路は `--hostname` / `--add-host`。
- `network_exists` は `GET /networks/{name}` の 404 を `false` に写像（context は container_lifecycle を流用し ContainerNotFound→false）。CLI 経路は `build_network_inspect_args` で `<runtime> network inspect <name>`、5 s timeout。
- `with_network` の名前は空・空白・改行を `validate_image_request` で拒否。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: `--hostname` / `--add-host` / `--network` の引数組み立て、キー・アドレス検証（空、空白、改行、不正 IP、IPv6）、`HostGateway` のランタイム別対応表、network preflight の純ロジック、hostname フォールバック規則（後方互換を含む）を検証する。
- Linux Docker 実機（CI の Docker ジョブ）で確認する。
  - テスト固有 name の network を事前作成して参照し、`exec` の `cat /etc/hosts` と `hostname` で反映を確認する。テスト後に network を削除する。
  - 存在しない network の事前拒否を確認する。host gateway は環境対応に依存するため結果を記録し、非対応環境は「未実行」またはスキップ理由を明記する。
- Apple Silicon 実機: `container network inspect` の存在確認、`container run` のフラグ有無の実測、`--network` 参照の挙動を確認する。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0030 の実機受入時に併せて実施する。
- ネットワークとコンテナは固有的な名前で作成・削除し、ユーザー所有リソースを消さない（`issues/README.md` の運用ルール 5）。

## リスク

- Apple CLI の `--hostname` / `--add-host` が実測で使えない場合、機能差が残る。preflight 拒否として明示し、XPC（0030）で回収する。
- `host-gateway` は Docker のバージョン依存であり、Podman 等でも解釈が異なる。非対応時は明示エラーにし、0022 の互換境界に記録する。
- hostname フォールバックを変えると既存利用者の見え方が変わる。明示指定時のみ付与する後方互換を既定にし、変更時は CHANGES に残す。
- network preflight の追加 inspect で起動レイテンシが増える。1 回の inspect に限定する。
- IP アドレス検証 API が見つからない場合、形式検証が簡易になる。採用した検証範囲を記録し、過信しない。
- ロールバック: フラグと builder の追加が中心で、既存引数を変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] with_hostname / with_host（ExtraHost / HostGateway）と network 事前検証を追加

## 注記

- upstream の対応物: [src/core/containers/request.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs)、[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)、[src/core/host.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/host.rs)、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)（extra hosts の Docker 配線と Apple の起動後追記）。
- Apple CLI の仕様は実装時に `container run --help` と実機で再確認する。ホスト到達の DNS 方式（`container system dns create ... --localhost`）は利用者向け doc の候補として記録する。
- 関連: 0004（preflight）、0010（Docker create）、0015（bridge IP）、0022（互換ランタイム）、0026 / 0030（XPC create と network inspect）、0047（Mac 専用オプション）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の Networking / platform / permissions 行。
- 証跡要件: `/etc/hosts` と hostname の実出力、preflight 拒否のログ、network inspect の結果を artifact に残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
