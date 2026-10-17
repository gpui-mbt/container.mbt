# [P0 / M3] tar 作成/展開と path traversal の安全性

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M3
Depends on: [0033](./0033-m3-copy-to-before-start.md), [0034](./0034-m3-copy-from-bounded-archive.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

copy 用 tar のエントリ名と投入先パスを、正規化の前に構造として検証し、`../`・絶対パス・`//`・終端 `.`・link / 特殊ファイルによる target 外書込を拒否する。tar サイズ、ヘッダ構造、エントリ数に上限を設け、異常 tar を無制限に読まない。

## 背景

- 0033 / 0034 が導入する ustar builder / parser は、`with_copy_to` の投入先パス（外部入力）とホストディレクトリ配下のファイル名を tar エントリ名へ変換する。投入先の検証を誤ると、コンテナ内の target 外を上書きし得る。
- upstream の `copy_to_sources_linux`（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)）は、投入先について絶対パス、末尾 `/` なし、終端 `.` なし、`//` なし、file name あり、`..`（ParentDir）なしを拒否する。正規化（`Path::components`）で消える前に文字列として検出することをコメントで明示している。ホスト側ソースは symlink と非 regular file を拒否し、walk 中の path 逸脱も拒否する。
- 展開側の `parse_first_regular_file_from_ustar`（[src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs)）は、hardlink（`1`）/ symlink（`2`）/ char device（`3`）/ block device（`4`）/ fifo（`6`）/ gzip を拒否し、directory は `IsDirectory`、空 archive は `EmptyArchive`、チェックサム不一致や truncate は invalid data にする。サイズは checked add で検証し、`Vec::with_capacity` を使わない。
- builder（docker_tar.rs の `UstarBuilder`）は name（100 バイト）/ prefix（155 バイト）への分割で空名・NUL・長過ぎを拒否し、directory エントリに末尾 `/` を、file エントリに末尾 `/` の不在を要求する。archive 全体（trailer 含む）は 64 MiB 上限（`DOCKER_RESPONSE_BODY_LIMIT`、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)）。
- 投入能力の契約は `ImageExt::with_copy_to`（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)）に記載があり、投入先に `..`・終端 `.`・空コンポーネントを含められないこと、1 ファイルと tar 全体の 64 MiB 上限、symlink / 特殊ファイルの拒否が明記されている。
- upstream には tar エントリ数の上限は定数として存在しない（parser は先頭エントリのみ、builder は自前生成）。件数上限は MoonBit 側で新たに定義する必要がある。

## 問題

- 投入先の `..`・`//`・終端 `.` は、パス正規化を行うと消えるため、正規化後に検証すると見逃す。
- link / 特殊ファイル / gzip の拒否と、サイズ・件数の上限が MoonBit の API として定義されていない。
- 異常 tar を無制限に読むと、OOM や誤展開につながる。

## 目標

- `../`、絶対パス、`//`、終端 `.`、末尾 `/`、file name なしを start 前に拒否する。
- link（hard / sym）・device・fifo・gzip を展開で拒否し、target 外書込を起こさない。
- tar の 1 ファイル / 全体サイズ、ヘッダ構造、エントリ数の上限がテスト可能な定数として存在する。
- 検証は正規化の前に行う。

## 対象外

- 0033 / 0034 の API と順序契約。本 issue は両者に共有される安全性規則が対象。
- 一般的な入力検証・リークの系統 fuzz（0054）。本 issue は copy 経路の決定的 fixture に限定し、ランダム生成の property-based 検証は 0054 へ委ねる。
- Docker daemon の tar 実装自体の挙動（本 issue は送信前検証と受信時 parse を対象にする）。

## 提案する方針

- 新規 `docker_tar.mbt`（0033 と共同。実装詳細として変更可）に検証関数を置き、builder / parser の入口で必ず呼ぶ。
- 投入先の文字列検証（正規化前、この順で）: 空、絶対（先頭 `/`）、`..` コンポーネント、`//`、終端 `.`、末尾 `/`、NUL 混入、file name が空になる形を拒否する。`make_path_relative` で相対化した後の値が空（`/` のみ）も拒否する。
- ホストソース: symlink と非 regular file を walk 中も含めて拒否する。walk の相対化で起点 root を外れた場合は拒否する。
- builder: `append_directory` は末尾 `/` 必須、`append_file` は末尾 `/` 不在を必須とし、name / prefix 長を超える場合は分割不能として拒否する。追記時の蓄積を 64 MiB と比較して fail-fast する（メタデータサイズ確認と上限 + 1 バイト読みで TOCTOU も検出）。
- parser: ヘッダ 512 バイト、magic `ustar\0`、8 進フィールド、チェックサムを検証する。typeflag は regular（`0` / NUL）のみ許可し、`1` / `2` / `3` / `4` / `6` と gzip magic は形式エラーにする。size は checked add でデータ末尾を検証し、残長不足は truncate エラーにする。`Vec::with_capacity(size)` は行わない。
- 上限: 1 ファイル / tar 全体 64 MiB（trailer 含む）。エントリ数の上限は upstream に定数がないため、MoonBit 側で有界値を決めて定数として固定し、値を docs に記録する（例の数値は実装時に決定）。
- エラー分類: パス不正（PathNameError 相当）、サイズ超過、形式不正（invalid data）、未対応形式（UnsupportedEntry 相当）を区別し、0017 / 0049 の分類へ載せる。

## 受け入れ条件

- [x] Given 投入先に `..` が含まれる, when copy-to を構成する, then archive 送信前に拒否される。（`validate_copy_target` が正規化前の文字列で `..` セグメントを拒否 — `with_copy_to` が構築時に raise）
- [x] Given 投入先が `//x` または `/tmp/.`, when copy-to を構成する, then 正規化で消える前に拒否される。（`//`・末尾 `.` は文字列検査で拒否 — wbtest 拒否行列で固定）
- [x] Given 相対の投入先または `/` のみの投入先, when copy-to を構成する, then 拒否される。（絶対パス必須 + root のみ拒否）
- [x] Given ホストソースに symlink または非 regular file が含まれる, when walk する, then 拒否される（黙って読み飛ばさない）。（`push_dir_tree` が `@fs.kind(follow_symlink=false)` で SymLink / 非 Regular を raise — 0033 で実装済、wbtest で固定）
- [x] Given 先頭エントリが hardlink / symlink / device / fifo / gzip, when parse する, then 未対応形式として拒否される。（typeflag 1/2/3/4/6/その他 → `UnsupportedEntry`、先頭 `0x1f 0x8b` → `GzippedArchive`）
- [x] Given tar 全体が 64 MiB を超える、または 1 ファイルが 64 MiB を超える, when build / parse する, then 切り詰めずエラーになる。（`ARCHIVE_MAX_BYTES`=64 MiB を builder 累積と parse 双方で強制 — 境界値丁度 / +1 の wbtest 済）
- [x] Given エントリ数が上限を超える, when build する, then 有界にエラーになる（上限値はテストで固定し、docs に記録する）。（`ARCHIVE_MAX_ENTRIES`=4096 — upstream には定数がないため MoonBit 側で定義し wbtest で 4097 個目の拒否を固定、docs/PORTING.md に記録）
- [x] Given チェックサム不一致・truncated header / data, when parse する, then 形式エラーになり panic しない。（`ChecksumMismatch` / `TruncatedData` / `BadHeader`（512 未満の非零入力）— 全て raise、panic なし）
- [x] Given builder が生成した tar, when 全エントリ名を検査する, then すべて起点ディレクトリ配下の相対パスであり、先頭 `/` と `..` を含まない。（builder の `header()` が構造検証（空名・NUL・先頭 `/`・`..`・`.` 成分・`//`）を正規化前に強制。加えて wbtest が実ディレクトリ walk で生成した tar の全エントリ名を舐めて相対性を検証 — 重複 directory エントリは `emitted_dirs` で抑止）
## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- wbtest: 拒否行列（`..`、`//`、絶対、終端 `.`、末尾 `/`、NUL、name / prefix 長超過）、ホスト側 symlink / 特殊ファイル拒否、typeflag / gzip / チェックサム / truncate の fixture、64 MiB の境界値、件数上限、エントリ名 golden。
- 悪意ある tar はバイト列を直接組み立てた決定的 fixture で表駆動する。ランダム生成による網羅は 0054 の入力検証シリーズで行う。
- Docker 実機（CI の Linux Docker ジョブ）: 正常 fixture が展開され、拒否対象は archive リクエストを発行しないことを確認する。生成 tar を GNU tar 等の既存実装で一覧表示できることを確認し、相互運用性の golden とする。
- 破壊的 fixture（`..` を含む tar など）は「リクエストを発行しないこと」の確認に留め、daemon へ送信して書込を試すテストは行わない。

## リスク

- 検証が厳しすぎて正当なパスを拒否する: 許可 / 拒否の行列をテストで固定し、upstream の実測（中間 `./` は許容）に合わせる。
- サイズ計算のミスによる巨大確保: checked arithmetic と capacity 事前確保なしで防ぐ。
- 件数上限の値が実運用に合わない: 上限値を docs に記録し、根拠を fixture の件数と併せて残す。
- ロールバック: `docker_tar.mbt` と検証関数の修正に閉じ、0033 / 0034 の順序契約を変更しない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] copy 用 tar の path traversal 検証とサイズ・件数上限を実装する

## 注記

- 主な参照: [src/core/client/docker_tar.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs)（builder / parser と 64 MiB 上限）、[src/core/copy.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs)、検証群は [src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)、契約文書は [src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)。
- 証跡: 拒否エラーの一覧、golden tar のエントリ名一覧、境界値テストの出力。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。0054 が入力検証とリークの系統検証を担当し、本 issue は決定的 fixture を提供する。
- 2026-11-04: 実装。`docker_tar.mbt` の `TarBuilder` に構造検証（空名・NUL・先頭 `/`・`..`/`.` 成分・`//`）を `header()` 入口へ追加し、`ARCHIVE_MAX_ENTRIES`=4096 の件数上限を導入（upstream に定数なし、docs 記録）。directory エントリは `emitted_dirs` で冪等化し push_parents の重複排出を抑止。parser は 512 未満の非零入力を `BadHeader`（truncated header）と EmptyArchive に分別。`copy.mbt` の `validate_copy_target` に NUL 拒否を追加。180 tests PASS、check --deny-warn PASS。生成 tar を GNU tar で一覧する相互運用性確認は CI に委譲（未実行と明記）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
