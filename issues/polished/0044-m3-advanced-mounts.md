# [P1 / M3] tmpfs size/mode・volume/read-only/bind の詳細互換

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md), [0026](./0026-m2-xpc-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`Mount` を upstream の `Mount` / `MountTmpfsOptions` に合わせて拡張する。tmpfs の size（バイトおよび `100k` / `100m` / `100g` 形式）と mode、アクセスモード、bind source の検証を追加し、ランタイム別の非対応組み合わせを副作用前に拒否する。

## 背景

- 現行の [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `Mount` は `Bind(String, String, Bool)` / `Volume(String, String, Bool)` / `Tmpfs(String)` の 3 形態と `with_read_only` のみで、tmpfs の size / mode を持たない。
- [commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` は `--mount type=...,target=...[,source=...][,readonly]` を組み立て、target の絶対パス、カンマ・イコールの禁止、bind source の絶対パスを検証する。
- upstream の [src/core/mounts.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs) は `MountType`（Bind / Volume / Tmpfs）、`AccessMode`（ReadOnly / ReadWrite）、`MountTmpfsOptions { size_bytes: Option<i64>, mode: Option<i64> }` を持ち、`with_size_bytes`（負値は panic）、`with_size`（`k`/`K` = 1000、`m`/`M` = 10^6、`g`/`G` = 10^9、単位なしはバイト、parse 失敗は panic）、`with_mode`（負値は panic）を提供する。tmpfs 以外では tmpfs オプションを反映時に無視する。
- Apple XPC 側の [src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs) は `Filesystem.options` に `ro` / `rw` と tmpfs の `size=` / `mode=`（mode は 8 進表記）を載せる。
- Apple CLI の `container run` は `--mount`（`type=,source=,target=,readonly`）と `--tmpfs <path>` を持つが、tmpfs の size / mode を渡す記法は文書化されていない。Docker CLI 側の記法も実装時に確認が必要。

## 問題

- tmpfs の size / mode を指定できない。upstream の `MountTmpfsOptions` 相当が欠けている。
- アクセスモードが `Bool` で表現され、upstream の `AccessMode` と対応しない。
- bind source は絶対パスと記号の禁止のみで、存在しないパスを渡すと run が遅く失敗する（副作用後）。
- ランタイム別の非対応組み合わせ（Apple CLI の tmpfs size / mode 等）を事前に拒否するマトリクスがない。

## 目標

- tmpfs の size（バイト、および `100k` / `100m` / `100g` 形式）と mode をモデル化する。size は 1000 進（upstream と同じ）。負値・overflow・不正形式は明示エラーになる。
- アクセスモードを `ReadOnly` / `ReadWrite` で表現し、既存の `with_read_only` と後方互換にする。
- bind source は絶対パス必須とし、存在確認を副作用前に行えるようにする（利用できる確認 API は実装時に確定）。
- ランタイム別に未対応の組み合わせを副作用前に拒否し、wbtest で検証可能にする。
- 既存の Bind / Volume / Tmpfs と read_only の構築結果に回帰がない。

## 対象外

- volume の解決・作成（0010 / 0026 / 0031 の範囲）。
- copy_to / copy_from と tar（0033 / 0034 / 0035）。
- Apple XPC の filesystem JSON 詳細そのもの（0026 / 0031）。本 issue は CLI adapter と公開モデルの範囲。
- Mac 専用の kernel / ssh / masked / readonly path オプション（0047）。
- マウントの権限・所有権（UID/GID）制御。

## 提案する方針

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `Mount` を拡張する（または新規 `mounts.mbt` へ移す。ファイル名と variant 形状は実装詳細として変更可）。一時的な案として、tmpfs 用に `TmpfsOptions { size_bytes : Int64?, mode : Int? }` を持つ variant を追加し、既存の `Mount::bind_mount` / `volume_mount` / `tmpfs_mount` / `with_read_only` は互換のまま残す。アクセスモードは `AccessMode` 相当（`ReadOnly` / `ReadWrite`）の enum を追加し、既存 Bool API をラップする。
- size の parse は upstream と同じ規則にする。`k`/`K` = 1000、`m`/`M` = 10^6、`g`/`G` = 10^9、単位なしはバイト。数値部は `@string.parse_int64` 等で parse し、`Int64` 乗算の overflow を検査する。負値と parse 失敗は `fail`（upstream は panic）とする。
- mode は非負の `Int` とし、負値は `fail`。Apple XPC 経路では 8 進表記で渡す（0010 / 0026 の serialization と整合）。
- bind source の検証: 絶対パスは既存どおり副作用前に強制する。存在確認は、実装時点で native で利用できる API（core または既存依存のファイル API）を確認して採用する。利用できる API がない場合は存在確認を実施できないため、その事実と代替（run 時のエラー分類）を issue 完了時に記録する。推測した API 名は使わない。
- ランタイム別マトリクス: Docker の `--mount` で tmpfs size / mode をどう渡すかを実装時に確認する。Apple CLI は文書化された記法に tmpfs size / mode がないため、指定時は副作用前に明示エラーにする（`--tmpfs <path>` のみ対応）。確認結果を wbtest のテーブルとして固定する。
- エラーは「どの mount のどの設定が、どのランタイムで未対応か」をメッセージに含める（0004 の preflight 方針と整合）。

## 受け入れ条件

- [ ] Given tmpfs mount に 100000 バイトの size, when Docker 経路で構築する, then 引数またはリクエストに size 相当の値が反映される。
- [ ] Given `with_size("100k")` / `"100m"` / `"100g"` / 単位なし, when parse する, then 100000 / 100000000 / 1000000000 / そのままになる。不正形式・負値・overflow は明示エラーになる。
- [ ] Given read-only でない mount と read-only mount, when コンテナ内から書き込む, then read-only 側のみ拒否される（Docker 実機）。
- [ ] Given 相対パスの bind source, when 構築する, then 副作用前に失敗する（既存動作の維持）。
- [ ] Given Apple CLI で未対応の tmpfs size / mode, when 指定する, then 副作用前に明示エラーになり、コンテナが作成されない。
- [ ] Given 既存の `Mount::tmpfs_mount` / `bind_mount` / `volume_mount` / `with_read_only` の利用箇所, when 再実行する, then 従来と同じ引数が組み立てられる。
- [ ] 既存 smoke の mount なし経路に回帰がない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: size parse の境界（`k`/`K`/`m`/`M`/`g`/`G`、単位なし、空文字、数字以外、負値、overflow、前後空白）、mode の検証、`--mount` 引数と XPC JSON（該当経路が入った後）の組み立て、ランタイム別拒否マトリクスを検証する。
- Linux Docker 実機（CI の Docker ジョブ）で確認する。
  - tmpfs size の実効をコンテナ内の `df` / mount 出力で確認する。
  - read-only 書込拒否と、存在しない bind source の事前拒否（存在確認 API を採用できた場合）を確認する。
- Apple Silicon 実機: Apple CLI の `--mount` / `--tmpfs` の実測（tmpfs size / mode の可否を含む）を行う。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録し、0031 / 0026 の受入時に併せて実施する。
- テスト用コンテナは固有 name に限定して後始末し、ユーザー所有ボリューム / コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- size の 1000 進 / 1024 進の誤解でテストが偽陽性になる。upstream と同じ 1000 進であることを doc と wbtest に固定する。
- Apple CLI の tmpfs size / mode が未対応の可能性。preflight 拒否に倒し、XPC（0026 / 0031）の対応範囲として明記する。
- 存在確認 API が core に見つからない可能性。採用可否と不足を実装時に記録し、できない検証を「できた」と扱わない。
- variant 拡張で既存コードのパターンマッチが壊れる。既存 constructor を維持し、ビルド時に検出できる範囲に留める。
- ロールバック: モデル拡張と preflight 追加が中心で、既存 mount の引数を変えない。問題時は revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] tmpfs size/mode と mount のアクセスモード・bind source 事前検証を追加

## 注記

- upstream の対応物: [src/core/mounts.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/mounts.rs)（`MountTmpfsOptions`、`with_size_bytes`、`with_size`、`with_mode`）、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)（Apple の `options` 生成、mode の 8 進表記）。
- Apple CLI の記法（`--mount type=,source=,target=,readonly` と `--tmpfs <path>`）は実装時に実機または最新の `container run --help` で再確認する。
- 関連: 0004（preflight）、0010（Docker create）、0026 / 0031（XPC mount）、0033 - 0035（copy / tar）、0047（Mac 専用オプション）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の ContainerRequest / labels / mounts 行。
- 証跡要件: size / mode の実効値（コンテナ内の mount 出力）、read-only 拒否、preflight 拒否のログを残す。実機が使えない確認は「未実行」と明記する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
