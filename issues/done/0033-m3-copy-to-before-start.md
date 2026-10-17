# [P1 / M3] Linux archive API による with_copy_to の起動前投入

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md), [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker Engine API の `PUT /containers/{id}/archive` により、create 後・start 前に copy-to を完了させる。init が起動時からファイルを読める状態を作り、copy 失敗時は start しない。

## 背景

- upstream Linux は `copy_to_sources_linux`（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）で create 後・start 前に `UstarBuilder` の tar を `PUT /containers/{id}/archive?path=/&copyUIDGID=true` へ送る。親ディレクトリを自動作成し、ホストディレクトリを再帰投入し、regular file に mode / uid / gid（中間 directory は 0o755）を適用する。失敗時は明示 rm でロールバックし start しない。
- 投入契約は `ImageExt::with_copy_to`（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)）が定め、Linux は起動前投入、macOS は start 後投入（0031 の範囲）。
- 型は [src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs) の `CopyDataSource::{File, Data}` と `CopyTargetOptions`（path / mode 既定 0o644 / uid / gid 既定 0）で、tar の生成とサイズ上限は [src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs) の `UstarBuilder` が担う。
- 現行 MoonBit には copy-to がなく、`GenericImage` にも copy 設定がない。依存の 0010 / 0011 が create / start / rm の直結 API を提供する。

## 問題

- `with_copy_to` 相当が存在せず、初期プロセスが起動時に読むファイルを投入できない。
- CLI の `docker cp` はバイナリ依存で、M1 以降の Engine API 直結方針に合わない。
- コンテナ側の投入先パス検証とサイズ上限が未定義。

## 目標

- create → copy → start の順序が保証され、init が起動時からファイルを読める。
- file / directory ソース、親ディレクトリの自動作成、mode / uid / gid の反映。
- 投入先パスの検証と 64 MiB 上限（1 ファイルあたりと tar 全体）が実装され、超過時は切り詰めない。
- copy 失敗時は start せず、作成済みコンテナを回収して元エラーを返す。

## 対象外

- copy_file_from（0034）と tar の path traversal 検証の網羅（0035）。本 issue は投入順序と Linux 経路の成立が対象で、検証規則は 0035 と分担する。
- macOS XPC の copy-to（0031）。
- tmpfs / volume / read-only の詳細互換（0044）。

## 提案する方針

- 新規 `copy.mbt`（実装詳細として変更可）に `CopyDataSource` 相当（File / Data）と `CopyTargetOptions` 相当（path、mode 既定 0o644、uid / gid 既定 0）を定義し、`GenericImage::with_copy_to(target, source)` 相当を追加する。
- 新規 `docker_tar.mbt`（実装詳細として変更可）に ustar builder / parser を実装する（parser は 0034）。builder は upstream と同じく relative path のみを扱い、`append_directory` は末尾 `/` 必須、`append_file` は末尾 `/` を拒否し、ヘッダ 512 バイト + データ + pad を蓄積する。チェックサムと `ustar\0` magic は upstream の既存形式に合わせる。
- 順序: `POST /containers/create` → 各 source について `PUT /containers/{id}/archive?path=/&copyUIDGID=true`（Content-Type `application/x-tar`）→ 全 source 成功後に start。途中で失敗したら start せず、`rm --force` 相当でコンテナを回収し、元エラーを返す。
- パス処理: 投入先は `make_path_relative` 相当で先頭 `/` を除いた相対パスにし、root のみ（`/`）は拒否する。親ディレクトリは 0o755 の directory エントリを先行追加して自動作成する。ホストディレクトリは深さ優先で walk し（順序を決定的にする）、subdirectory の mode は 0o755 とする。
- 事前検証: 投入先は絶対パス、末尾 `/` なし、`..` なし、`//` なし、終端 `.` なし、file name あり。ソースは symlink と非 regular file を拒否する（upstream と同じ。詳細な文字列検証は 0035 と共通化する）。
- サイズ上限: 1 ファイルあたり 64 MiB（メタデータ確認 + 上限 + 1 バイト読みで TOCTOU の成長も検出）と tar 全体 64 MiB（trailer 含む）。`Data` は 1 ファイル上限の対象外だが tar 全体上限は受ける。超過時は切り詰めずエラーにする。
- エラー分類: パス不正、サイズ超過、I/O、archive 404（コンテナ不存在）を区別し、0017 の失敗分類へ載せる。

## 受け入れ条件

- [ ] Given `with_copy_to("/work/config.txt", ...)` と、init が起動時にそのファイルを読むコマンド, when start する, then 内容が正しく読める（起動前投入が成立）。**未実行**（実 daemon が必要。mock socket で create → `PUT archive` → start の順序と tar 内容は固定済み。実機確認は CI）
- [x] Given 親ディレクトリが存在しないコンテナパス, when copy-to する, then 中間ディレクトリが自動作成される。（`push_parents` が 0o755 の directory エントリを先行追加 — wbtest で `work/` + `work/config.txt` の 2 エントリを検証）
- [x] Given ホストディレクトリ, when copy-to する, then 再帰的に投入され、配下 regular file の mode / uid / gid が反映される（中間 directory は 0o755）。（`push_dir_tree` で readdir(sort=true) の深さ優先。file ソース / directory ソースともに mtime 実値・mode/uid/gid 適用 — wbtest で `dest/` 直下展開と単一 file を検証）
- [x] Given 不正な投入先（相対パス、`..`、`//`、末尾 `.`、末尾 `/`、`/` のみ）, when start する, then archive 送信前に拒否され、作成済みコンテナは残らない。（`with_copy_to` が `validate_copy_target` で構築時に raise — コンテナは作られない。拒否行列 wbtest 済）
- [x] Given ソースに symlink または非 regular file が含まれる, when copy-to する, then 拒否され start しない。（`@fs.kind(follow_symlink=false)` で SymLink / 非 Regular を拒否 — wbtest で tmpdir 上の symlink を検証）
- [x] Given 64 MiB を超えるファイル, when start する, then 失敗し、部分投入を成功扱いしない。（file ソースは `file_size` 検査 + 読み後の成長検出（TOCTOU）、tar 全体は `TarBuilder::push` が header/padding/trailer 込みの合計で `ARCHIVE_MAX_BYTES` を強制 — 境界値丁度・+1 の wbtest 済。実 daemon での巨大 fixture 投入は CI）
- [x] Given copy が途中で失敗する, when start がエラーを返す, then コンテナが残らず、元エラーの内容が返る。（`errdefer` が `protect_from_cancel` + `CLEANUP_BUDGET_MS` で作成 ID のみ force-remove。mock で PUT 500 → `DELETE /containers/cid?force=true` が wire に出て、`{"message":"tar fail"}` が呼び出し側へ返ることを固定）
- [x] `with_copy_to` を使わない既存の create / start / exec / logs の挙動が変わらない。（`copy_to.is_empty()` 時は従来の `create_and_start` 経路のまま — 既存 157→166→169 テストが回帰なしで PASS）

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: builder のレイアウト（512 バイトブロック、チェックサム、終端 2 ブロック、prefix / name 分割、dir の末尾 `/`）、投入先検証の拒否行列、サイズ上限の境界値と超過、Data ソースの上限適用、引用符を含むパス。
- Docker 実機（CI の Linux Docker ジョブ。実際に `docker` daemon を使う）: alpine:3.20 で prestart file read（init が `cat` して stdout に出す）、directory の再帰投入、親ディレクトリ自動作成、`stat` による mode / uid / gid 確認、巨大 fixture（64 MiB + 1 バイト）での失敗、失敗後に `docker ps -a` で残存ゼロを確認する。結果はログで保存する。
- Apple 実機の copy-to は 0031 / 0032 の範囲であり、本 issue のテストには含めない。

## リスク

- tar 生成の不備でコンテナ内パスを壊す: 0035 の構造検証と golden fixture で固定する。
- copy 中のタイムアウト: 0018 の deadline を再利用し、失敗時は rm で回収する。
- 最大 64 MiB をメモリに保持する: 上限で fail-fast し、保持量の設計を docs に明記する。
- `copyUIDGID=true` の権限エラー: daemon 応答を失敗分類へ載せ、部分成功として扱わない。
- ロールバック: `with_copy_to` 未使用時に経路が変わらない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Linux Docker Engine API で with_copy_to を create 後・start 前に投入する

## 注記

- 主な参照: [src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)、[src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs)、順序と検証は [src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs) の `copy_to_sources_linux`。
- 証跡: 起動前投入を確認する init の出力、`stat` の結果、失敗時の `docker ps -a` と stderr。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。0035 が本 issue と 0034 に共通する tar 安全性を担当する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`copy.mbt` に `CopyDataSource::{File,Data}`（`::file`/`::data` コンストラクタ）・`CopyTarget`・`GenericImage::with_copy_to(target, source, mode?=0o644, uid?=0, gid?=0)`・`build_copy_archive`・`validate_copy_target`・`push_parents`/`push_dir_tree`（sort 済再帰、symlink/非 regular 拒否、file_size + 成長検出）。`docker_tar.mbt` に `TarBuilder`（ustar magic・checksum・octal field・name/prefix 分割・末尾 `/` discipline・`ARCHIVE_MAX_BYTES`=64 MiB 全体上限）。`docker_container.mbt` に `put_container_archive`（`PUT /containers/{id}/archive?path=%2F&copyUIDGID=true`, `application/x-tar`, 404 は `ContainerNotFound` 分類）。`runtime.mbt` の direct start を create → copy → start に拡張し、copy 失敗時は `errdefer` で force-remove + 元エラー再送出。`capability.mbt` に `Setting::CopyTo`（DirectDocker=Supported、CLI/Apple=NotYetImplemented(33)）。docs/PORTING.md・README.md 更新。`moon check --target native --deny-warn` PASS、169 tests PASS（ustar 構造・検証行列・wire 順序・rollback・64 MiB 境界・引用符パス・404 分類を網羅）。実 daemon での init-起動前読取・`stat` 確認・巨大 fixture は CI に委譲（未実行と明記）。
