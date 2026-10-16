# [P1 / M3] copy_file_from でファイルを安全に取り出す

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の `GET /containers/{id}/archive` と ustar parser により、コンテナ内の単一ファイルを bytes またはホストファイルとして取り出す。directory・link・特殊形式・64 MiB 超過・部分データを成功として返さない。

## 背景

- upstream は `DockerClient::copy_from`（[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)）で `GET /containers/{id}/archive?path=...` を実行し、応答 tar 全体を 64 MiB 上限（`DOCKER_RESPONSE_BODY_LIMIT`）で蓄積する。404 はボディの `{"message": ...}` を読み、`Could not find the file ` で始まる場合は「コンテナ内パス不存在」、それ以外は「コンテナ不存在」に分類する。
- 公開 API は `CopyFileFromContainer` トレイト（[src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)）で、`PathBuf`（ホストファイルへ書き出し）と `Vec<u8>`（bytes 取得）の実装を持つ。
- tar の解釈は `parse_first_regular_file_from_ustar`（[src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs)）が担う。先頭エントリのみを対象にし、directory は `IsDirectory`、空 archive は `EmptyArchive`、hardlink / symlink / char device / block device / fifo / gzip は `UnsupportedEntry`、チェックサム不一致や truncate は invalid data として拒否する。データ長は checked add で検証し、`Vec::with_capacity(size)` は使わない（破損入力による OOM 回避）。
- macOS の copy-out は `XpcClient::copy_out`（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）が `containerCopyOut` で一時ファイルへ写し、そのリーダーを公開 API へ渡す。
- 現行 MoonBit には copy-from がなく、依存の 0011 / 0007 が lifecycle と HTTP framing を提供する。

## 問題

- copy-from の公開 API が存在せず、コンテナ内ファイルを取り出せない。
- tar の単一エントリ解釈、404 の 2 分類、64 MiB 上限、部分データの扱いが未定義。

## 目標

- 単一 regular file の内容を bytes / ホストファイルとして取得できる。
- directory は明示エラー、不存在コンテナと不存在パスを区別できる。
- 64 MiB 超は切り詰めずエラーになる。
- 破損・途中切断時に部分データを成功として返さない。
- gzip・link・特殊ファイルを安全に拒否する。

## 対象外

- copy-to（0033）と tar の path traversal 検証の網羅（0035）。本 issue は取得経路と形式判定が対象。
- macOS の copy-to（0031）。macOS の copy-out は本 issue に含めるが、実機検証は 0032 の受入で行う。
- 64 MiB 超のストリーミング取得（無界の streaming は行わず、別 issue とする）。

## 提案する方針

- 公開 API は `Container::copy_file_from(path, target)` 相当とし、target はホストファイルパス / bytes の 2 形式（upstream の `CopyFileFromContainer` 相当）。runtime に依らず同じ契約にする。
- Docker 経路: `GET /containers/{id}/archive?path={percent_encode(path)}` を送り、応答 tar 全体を 64 MiB 上限付きで受信する（上限超過はその場でエラー）。404 はボディの `message` を parse し、`Could not find the file ` で始まる場合はパス不存在、それ以外（非 JSON・空・未知文言）はコンテナ不存在に寄せる（安全側の既定）。
- tar 解釈: 先頭 512 バイトのヘッダを検証し、magic / checksum / typeflag を判定する。regular file（typeflag `0` / NUL）以外は形式エラー、gzip magic（`0x1f 0x8b`）は形式エラー、size は checked add でデータ末尾を検証し、不足は truncate エラーにする。size からの capacity 事前確保はしない。
- 部分データ: 受信・parse のどこかで失敗したら、得られた分を返さずエラーにする。ホストファイル出力形式は upstream と同じくファイルを作成してコピーするため、失敗時に部分ファイルが残り得ることを docs に明記し、成功扱いはしない。
- macOS 経路: `containerCopyOut` で一時ファイルへ写して reader に渡し、copy 完了後に一時ファイルを削除する。ホスト側 destination の相対パスは呼び出し側の cwd 基準で絶対化する（upstream と同じ）。
- 404 分類と上限は 0017 の失敗分類へ載せ、テストで再利用できる型にする。

## 受け入れ条件

- [ ] Given コンテナ内に既知内容の regular file, when copy_file_from する, then bytes が内容と一致する。
- [ ] Given directory のパス, when copy_file_from する, then `IsDirectory` 相当のエラーになり、部分データを返さない。
- [ ] Given 不存在コンテナ, when copy_file_from する, then コンテナ不存在エラーになる（パス不存在と混同しない）。
- [ ] Given 不存在パス, when copy_file_from する, then パス不存在エラーになる。
- [ ] Given 64 MiB を超えるファイル, when copy_file_from する, then 切り詰めずエラーになる。
- [ ] Given 先頭エントリが symlink / hardlink / device / fifo / gzip, when parse する, then 形式エラーで拒否される。
- [ ] Given チェックサム不一致や truncated data, when parse する, then エラーになり部分データを成功扱いしない。
- [ ] ホストファイル出力は成功時のみ内容が一致し、失敗時の部分ファイル残留が docs に明記されている。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: parse の golden（regular / directory / 空 archive / gzip / 各 typeflag / チェックサム不一致 / truncated data / size overflow）、64 MiB の境界値と超過、404 文言の分類（`Could not find the file ` の prefix、空ボディ、非 JSON、prefix を偽装した文言）。
- Docker 実機（CI の Linux Docker ジョブ）: `docker exec` で既知内容のファイルを作り copy_file_from で取得してバイト一致を確認、directory のエラー、不存在パスの 404 分類、巨大ファイルの失敗を実行する。終了後に `docker ps -a` でテストコンテナの残存ゼロを確認する。
- Apple 実機の copy-out（`containerCopyOut`）は 0032 の受入項目として実施する。実行できるまで「未実行」と記録し、CI compile-only で代用しない。

## リスク

- 404 文言への依存: prefix match と安全側 fallback で誤分類を避け、文言 drift は 0053 で追跡する。
- 巨大応答によるメモリ消費: 64 MiB で fail-fast する。
- 破損 tar による OOM / panic: checked arithmetic と capacity 事前確保なしで防ぐ。
- 一時ファイルの残留: copy 完了 / 失敗の全経路で削除を確認する。
- ロールバック: 新規 API と parser に閉じ、既存経路を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] copy_file_from でコンテナ内ファイルを安全に取得する（64 MiB 上限・404 分類）

## 注記

- 主な参照: [src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)、[src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs)、404 分類は [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) の `classify_archive_404`、macOS は [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs) の `copy_out`。
- 証跡: 404 応答ボディ、取得バイトの比較ログ、`docker ps -a` の前後。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。0035 が builder / parser の安全性を共通で担当する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
