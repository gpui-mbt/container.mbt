# [P0 / M1] Docker Engine API の create/start と request serialization

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M1
Depends on: [0006](./0006-m1-docker-unix-socket-transport.md), [0007](./0007-m1-docker-http-framing-parser.md), [0009](./0009-m1-native-image-pull.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

GenericImage の設定を Docker Engine API の create request（JSON）へシリアライズし、`POST /containers/create` で得た ID を `POST /containers/{id}/start` で起動する。CLI（`docker run`）を使わず、start 失敗時は作成した ID だけを rollback する。

## 背景

- 現行 M0 は `runtime.mbt` の `GenericImage::start` が `commands.mbt` の `build_run_args` で `docker run --detach` の argv を組み立て、`@shell.Cmd` で実行して stdout から ID を得る CLI adapter のみで、Docker API の create request 型を持たない。
- M1 は Linux で Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析、0009 が image pull を担当し、本 issue はその上に載る create/start を担当する。
- upstream では `src/core/client/docker_client.rs` の `CreateContainerBody::from_config` が `ContainerConfig` を create request へ変換し、`create_container` が `POST /containers/create` の応答から `Id` を読む。`start_container` が `POST /containers/{id}/start` を呼ぶ。start 失敗時の回収は `src/runners/async_runner.rs` が create で得た ID に対して `remove(force=true)` を await する（`rollback_remove`。既定は回収し、`TESTCONTAINERS_COMMAND=keep` のときだけ抑止）。

## 問題

- `build_run_args` は command/entrypoint/env/labels/working dir/user/network/platform/readonly rootfs と port mapping を argv にしか変換しない。Docker API の `Image`/`Cmd`/`Entrypoint`/`Env`/`Labels`/`HostConfig`/`PortBindings` の組み立てと JSON 化が未実装。
- `runtime.mbt` の `start` は CLI stdout から ID を受け取るため、API 経由の「作成済み ID」を保持して start する二段階処理と、start 失敗時にその ID だけを回収する rollback が存在しない。
- 現行 `start` は `mappings` と `ready_conditions` の snapshot を取るが、create request 全体の snapshot 型がない。start 後に builder を変更しても起動済みコンテナの request と port に影響しない契約を API 経路でも維持する必要がある。

## 目標

- GenericImage から create request の snapshot を構築し、Docker が受理する JSON へシリアライズする。
- `POST /containers/create` → `POST /containers/{id}/start` の順で実行し、start 失敗時は作成した ID を force remove で回収する。
- API 起動経路が `docker`/`container` CLI プロセスを起動しない。
- 既存の副作用前検証（重複 port の拒否、container name 検証、mount 引数検証）と snapshot 契約を API 経路でも維持する。

## 対象外

- transport/HTTP 解析/image pull は 0006、0007、0009。inspect/stop/rm/wait は 0011、exec は 0012、logs は 0013、動的 port は 0014。
- 公開 API の CLI から API への切り替えと capability gate は 0019。本 issue は直結経路を呼び出せる形で提供し、選択規則は 0019 に譲る。
- startup deadline と cancel の共通伝搬は 0018。mounts の詳細互換は 0044、hostname/ExtraHost/network 拡張は 0045、resource/security 設定は 0046、override 契約は 0048。
- Apple XPC の create/start と rollback は M2 の 0026。CLI adapter の run 失敗時 orphan 回収は 0001。Linux 直結の起動〜削除 E2E 受入は 0020。

## 提案する方針

- 直結クライアント用の新規ファイル（例: `docker_client.mbt`、実装詳細として変更可）に create request の型と JSON シリアライザを置く。upstream `CreateContainerBody::from_config` の構造に対応させる。
  - query: `container_name` 指定時は `name`、`platform` 指定時は `platform` を percent-encode して付与する。
  - body の主な member: `Image`（`descriptor()`）、`Entrypoint`（本ライブラリは単一文字列のため `Some` のとき 1 要素配列。空文字の意味論は 0048 と整合させる）、`Cmd`、`Env`（`KEY=VALUE` 形式の配列）、`Labels`、`WorkingDir`、`User`、`ExposedPorts`（`{"80/tcp":{}}` 形式）、`HostConfig.PortBindings`（`{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}` 形式。host port 0 はエフェメラル要求としてそのまま送る）、`HostConfig.ReadonlyRootfs`、network 指定時は `NetworkingConfig.EndpointsConfig`。
  - 既存 `with_mount` の Bind/Volume/Tmpfs は最低限 `HostConfig.Binds`/`HostConfig.Mounts` へ変換し、tmpfs の size/mode など詳細互換は 0044 に残す。
  - JSON のエスケープは専用ヘルパーへ一元化し、値の文字種を wbtest で固定する。
- create の前に既存検証（重複 container port、name 形式、startup timeout 正値、mount 引数）を再利用し、副作用を起こさない。upstream も pull 前に重複 port を明示拒否する。
- create 応答は `Id` を必須として読む。欠落・空文字はエラーにし、start は空 body で送って 2xx を成功として扱う（それ以外は 0017 の分類へ渡す）。
- start 失敗時: 直前の create が返した ID に限定して `DELETE /containers/{id}?force=true` を独立した短い予算（例: 5 秒）で実行する。回収の失敗で元の start エラーを上書きせず、回収結果をエラー文面へ付記できる形にする。name での再解決はしない。
- snapshot: create request は構築時に配列をコピーし、start 後の `GenericImage` 変更が request/port に影響しないようにする（既存 `mappings` snapshot 契約と揃える）。
- 既存 CLI 経路のテスト（`commands_wbtest.mbt`、`image_wbtest.mbt`、`runtime_wbtest.mbt`）は変更しない。API 経路はテストから直接呼べる internal API とし、`smoke` 系の切替は 0019/0020 で行う。

## 受け入れ条件

- [ ] Given イメージが解決済み, when GenericImage の設定で API の create/start を実行する, then 作成 ID のコンテナが running になり、`docker` CLI プロセスが一度も起動しない。
- [ ] Given `with_cmd`/`with_entrypoint`/`with_env_var`/`with_label`/`with_working_dir`/`with_user`/`with_readonly_rootfs` を設定する, when create request をシリアライズする, then 各設定に対応する member が fixture JSON と一致する。
- [ ] Given `with_mapped_port` と `with_exposed_port` を設定する, when create request をシリアライズする, then `ExposedPorts` と `HostConfig.PortBindings` が protocol 付きキーで一致し、host port 0 がエフェメラル要求として送られる。
- [ ] Given 同一 container port を重複指定する, when start を呼ぶ, then pull や create の副作用前にエラーになり、コンテナは作成されない。
- [ ] Given start が失敗する, when start がエラーを返す, then create で得た ID だけが force remove され、元の start エラーがそのまま呼び出し側へ返る。
- [ ] Given start 成功後に builder を変更する, when container の port mapping を読む, then start 時点の snapshot が返る（既存契約の維持）。
- [ ] Given create 応答が `Id` を欠く, when 応答を解析する, then 空 ID で start せず、エラーを返して資源を残さない。
- [ ] 既存の CLI 経路テストと M0 の orphan 回収（0001）が回帰しない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: create request JSON の fixture 比較（`Cmd`/`Entrypoint`/`Env`/`Labels`/`WorkingDir`/`User`/`ExposedPorts`/`HostConfig`/`ReadonlyRootfs`）、name/platform query のエスケープ、重複 port の副作用前拒否、snapshot 不変。
  - fake Engine（Unix socket。0006/0007 のテスト基盤を共有）で、create 成功 → start 500 → `DELETE ...?force=true` が同一 ID に発行されることを確認する。
- Linux Docker 実機（CI の Docker ジョブ）: daemon-backed test で API のみを使い Alpine を create/start し、inspect で running を確認してから force remove する。検証プロセスの `PATH` から `docker` 実行ファイルを外して実行し、CLI 非依存を観測する。残存確認は API の inspect、または別プロセスの `docker ps -a` で行い、前後の結果を証跡として残す。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外。Mac の CLI adapter は既存 `smoke_apple` の範囲で回帰確認とし、実行できない間は理由付きで「未実行」と記録する（0002 の実機受入時に併せて確認）。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- JSON シリアライズの不一致で daemon の挙動が変わる。upstream 構造との fixture 比較と実機 create の両方で検証する。
- rollback による誤削除。対象は create が返した所有 ID に限定し、name や label 検索で他コンテナを探さない。
- `HostConfig.PortBindings` の HostIp を upstream と同じ `0.0.0.0` に固定すると IPv6 binding が生まれない可能性がある。0014 の実機確認と結果を整合させる。
- snapshot を取らないと start 後の builder 変更が request に混入する。request 型を builder から分離して防ぐ。
- 既存 CLI 経路への影響。公開 API と CLI 引数組み立てに触れず、追加ファイルに閉じる。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker Engine API 直結の container create/start と失敗時 rollback を実装する

## 注記

- upstream 参照: [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`create_container`、`start_container`、`CreateContainerBody`、`HostConfig`）、[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)（create→（起動前 copy）→start と `rollback_remove`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡: create request の fixture、create/start 応答、rollback 前後の `docker ps -a` をログまたは artifact に残す。
- 0001 の CLI orphan 回収とは経路が異なるが、「所有を証明できる ID のみ回収する」方針を共有する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
