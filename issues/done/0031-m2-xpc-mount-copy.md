# [P1 / M2] Apple XPC bind/volume/tmpfs とコピーの互換検証

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC の mount 変換（bind / volume / tmpfs、source / target / access mode）を実装し、macOS では起動前 bind と poststart copy という順序契約をテストで区別できるようにする。read-only mount への書込拒否も実機で確認する。

## 背景

- 現行 MoonBit は [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `Mount`（`Bind` / `Volume` / `Tmpfs` と `with_read_only`）を [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `--mount` 文字列へ変換するのみで、XPC の config 変換はない。
- upstream の `Mount`（[src/core/mounts.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs)）は `MountType::{Bind, Volume, Tmpfs}` と `AccessMode::{ReadOnly, ReadWrite}`（表示は `ro` / `rw`）を持つ。
- XPC 変換は `mount_cfg`（[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)）が行う。Bind は fs_type `virtiofs` とホスト source、Volume は `volume_resolutions` で解決した実体パス（ファイルシステム形式付き）、tmpfs は source `tmpfs` と fs_type `tmpfs`。options は ro / rw を先頭に置く。
- Apple container は volume を block デバイスとして扱うため、ボリューム名のままではマウントできない。`XpcClient::resolve_volume`（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）が `volumeCreate` → 既存なら `volumeInspect` で実体を解決する。自動作成されたボリュームは起動失敗時も残る（Docker の自動作成と同じ挙動）。
- copy のタイミングは OS で異なる（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs) の `with_copy_to` doc）。Linux は create 後・start 前で起動前投入の契約がある。macOS は `start_process` 後の `containerCopyIn`（running 必須）で、初期プロセスが起動時に読む用途には bind（virtiofs）を使う。`createParents: true`、`fileMode` のみ反映、uid / gid はコピー後の `chown` exec で反映し、失敗は warn のみとする（[src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)）。
- macOS の bind は `host_path` を絶対パスかつ実ファイル / 実ディレクトリで渡す前提で、相対パスは apiserver 側の cwd で解決される。symlink は未検証のため対象外。`CopyDataSource::Data`（インメモリ bytes）の起動前投入も対象外。

## 問題

- XPC の mount 変換がなく、volume の実体パス解決、ro / rw、tmpfs が未実装。
- macOS の copy-to が poststart であること、起動前投入に bind を使うことがコードと文書で結びついていない。
- read-only mount への書込が実際に拒否されることを検証した記録がない。

## 目標

- Bind / Volume / Tmpfs が XPC config へ変換され、source / target / access mode の意味が upstream と一致する。
- macOS では copy-to が start 後であること、bind が起動前から見えることをテストで区別できる。
- volume 名が実体パスへ解決され、存在しない volume は自動作成される。
- read-only mount への書込が失敗する。
- volume / tmpfs / copy のサポート差が docs と事前検証に反映される。

## 対象外

- Linux の copy-to / copy-from と tar（0033–0035）。macOS からのファイル取り出し（copy-out）は 0034 で扱う。
- tmpfs の size / mode オプションと bind / volume の詳細互換（0044）。本 issue は 3 種の基本変換と ro / rw に限定する。
- macOS 専用の kernel / ssh / masked / readonly path オプション（0047）。

## 提案する方針

- 0024 が定める XPC config 構築に mount 変換を追加する（例: `container_cfg.mbt`（新規、実装詳細として変更可））。変換規則は upstream の `mount_cfg` に合わせる。
  - Bind: source は絶対パスを要求し、fs_type `virtiofs`。symlink は未対応として明示エラーにする。
  - Volume: `resolve_volume` 相当を XPC client に追加し、`volumeCreate` → already exists なら `volumeInspect` で実体パスと形式を解決してから使う。ボリューム名の事前検証（英数字始まり、255 文字以内など upstream の規則）も行う。
  - Tmpfs: source `tmpfs`、fs_type `tmpfs`。destination は絶対パスを要求する。
- options は `ro` / `rw` を先頭に置き、read-only の意味を upstream と揃える。
- copy-to の macOS 順序（start_process 後）を正式契約とし、`createParents: true` を渡す。File ソースはパスを直接渡し、Data ソースは一時ファイルへ書き出して copy 後に削除する。uid / gid が非 0 のときは `chown` を exec で実行し、失敗は warn に留める。
- 起動前にファイルを見せたい利用者へは bind（virtiofs）を案内し、契約差を README または docs に明記する。
- read-only 検証は実機でコンテナ内から書込を試み、失敗を観測する。エラー種別の文言は実機観測で確定し、決め打ちしない。
- 相対 source / destination や未対応の組み合わせは config 構築の時点でエラーにする（副作用前）。

## 受け入れ条件

- [ ] Given bind mount を指定する, when コンテナの init が起動直後にファイルを読む, then 読める（起動前から可視）。
- [ ] Given copy-to を指定する, when 起動する, then 投入は init 起動後に行われ、テストが「起動後投入」を観測できる（ログマーカーとファイル到着の順で確認）。
- [ ] Given volume 名を指定する, when 起動する, then 実体パスへ解決されてマウントされる。存在しない volume は自動作成され、起動失敗時も残る。
- [ ] Given tmpfs の destination, when 起動する, then tmpfs としてマウントされる。
- [ ] Given read-only mount, when コンテナ内から書込む, then 拒否される。
- [ ] Given 相対 source / destination, when config を構築する, then コンテナ作成の前にエラーになる。
- [ ] CLI adapter の `--mount`（M0）の挙動は変更されない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: mount 3 種 × ro / rw の config 変換、相対パス拒否、volume resolution の already exists 分岐（mock）、Data ソースの一時ファイル後始末。
- Apple Silicon 実機（macOS 26+。CI に物理 Mac は存在しない）: bind / volume / tmpfs の fixture、copy-to の順序観測、read-only への書込拒否、uid / gid の chown 反映と失敗時の warn を確認する。実行できるまで「未実行」と記録し、CI compile-only で代用しない。0032 の受入へ含める。
- 実機証跡: mount 一覧（inspect 相当）、起動ログマーカー、書込エラーの生メッセージ。

## リスク

- virtiofs のライブ書き換え可視性は実測されていない: 断定せず、docs に不確定事項として残す。
- volume 自動作成物の残留: upstream と同じ挙動であることを docs に明記する。
- copy 後の一時ファイル残留: copy 完了後に必ず削除し、テストで確認する。
- chown 失敗の握りつぶし: warn ログに残し、実機で観測する。
- ロールバック: config 変換と copy 経路に閉じ、CLI adapter の `--mount` を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Apple Container XPC の bind/volume/tmpfs マウント変換と copy-to を実装する

## 注記

- 主な参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（`resolve_volume` / `copy_in`）、[src/core/mounts.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs)、[src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)、[docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md)。0032 が実機受入の窓口で、0033–0035 の Linux copy 契約と混同しない。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

bind / volume / tmpfs の config 変換、volumeCreate/Inspect、post-start `containerCopyIn`、Data 一時ファイル、ro/rw、chown 経路を実装。`smoke_xpc` で bind 読み取り・read-only 書込拒否・tmpfs が PASS。Apple Container 1.5.0 へ更新後、`smoke_xpc_extra` で copy-in（Data → `/copied` = `copy-data`）と volume mount（`/vol/x` の write/read）が PASS。masked/readonly は 0047 で PASS。

追記: 2026-10-17 に Apple Container 1.5.0 へ更新し、copy-in と volume mount を実機確認した。
