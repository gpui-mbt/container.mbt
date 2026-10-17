# [P1 / M0] CLI adapter の非対応設定を副作用前に明示拒否する

Status: done
Model: SWE-2 Max
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M0
Depends on: なし
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker / Apple Container CLI adapter に runtime 別の capability 表を導入し、未対応・未確認の設定を run / pull の副作用前に明示エラーで拒否する。CLI に黙って捨てられる設定を許可しない。

## 背景

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `GenericImage` builder は両 CLI 共通で、[commands.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt) の `build_run_args` が引数化と検証を一手に引き受ける。現状は container name / startup timeout / wait 条件 / env / label / container port 重複 / mount 形式と、Apple 限定で host port 0・SCTP を検証している。
- upstream は pull 前に `linux_unsupported_request_reason`（Linux 未対応の設定を明示エラー）と `reject_sctp_ports`（Apple の SCTP を "SCTP port publishing is not supported on Apple container" で拒否）、`reject_duplicate_mapped_ports`（同一 container port の重複を後勝ちで潰さずエラー）を実行し、`normalize_platform` で platform を amd64 / arm64 に限定する（[src/runners/async_runner.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/runners/async_runner.rs)、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)、[src/core/containers/request.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs)）。
- Apple Container には `hostPort: 0` のランダム割当が無く、upstream は空きホストポートを事前確保してから渡す（`allocate_unique_free_host_port`）。現行 MoonBit は `with_exposed_port` を Apple で拒否しており、この差を capability として明示する必要がある。

## 問題

- runtime 差が `build_run_args` 内の散在した `if runtime is AppleContainer` に埋もれており、設定項目ごとの適用 / 拒否の一覧が無い。
- runtime 差の検証が無い設定が残っている: `--platform`（upstream は許可値を限定）、`--network`、`--user`、mount 各種（bind / volume / tmpfs の Apple CLI 実サポートは未確認）。未確認のまま渡すと CLI 側の解釈差がそのまま実行時エラーになる。
- 重複 container port は拒否しているが、host port の重複や platform の不正値の扱いは CLI 任せになっている。
- 検証が引数組み立てと混在しており、「副作用（run / pull）前に拒否される」ことをテストで示しにくい。

## 目標

- runtime ごとの capability 表（設定 × Docker / Apple の適用・拒否・未確認）を持つ。
- すべての設定が「適用」か「副作用前の明示エラー」のどちらかになる。黙殺は許可しない。
- 拒否時は run / pull が一度も spawn されない。
- エラー文言に設定名・runtime・理由（可能なら upstream 相当の文言）を含める。
- 既存の成功パス（smoke の Alpine + 固定 port + message wait）の生成引数を変えない。

## 対象外

- direct Engine API 側の検証（0010、0017）。
- Apple XPC の capability（0024、0030）。
- dynamic host port / bridge IP の実装（0014、Apple は 0030）。
- Builder API の追加・改名（0048）と、公開エラー型の全面整備（0049）。

## 提案する方針

- 新規 `capability.mbt`（仮）に `runtime × 設定種別 -> 適用 / 明示拒否（理由）` を返す純粋関数を置き、`build_run_args` の先頭で呼ぶ。ファイル名・関数名は実装詳細として変更可。
- 現行 `build_run_args` の検証をすべて表へ移し、upstream の preflight に相当する項目（SCTP、重複 container port、host port 0、platform 許可値）を載せる。
- 「未確認」項目は許可しない。Apple CLI の `--network` / `--mount` 種別 / `--platform` の対応可否は CLI help と 0002 の実機セッションで確認してから「適用」へ格上げする。それまで開始できない設定は明示エラーにする。
- 拒否の文言は upstream の該当メッセージを参考にする。例: SCTP は "SCTP port publishing is not supported on Apple container" 相当とする。
- host port の重複検出・platform 不正値の扱いは、Docker CLI / Apple CLI の実挙動と upstream の対応（`reject_duplicate_mapped_ports`、`normalize_platform`）を確認して表に反映する。実確認なしに拒否仕様を断定しない。
- `build_run_args` は純粋関数のまま維持し、run / pull の呼び出しより前に検証が評価される構造を保証する。

## 受け入れ条件

- [x] Given Apple runtime と SCTP mapping, when `start` する, then run が spawn されず、SCTP 非対応を示す明示エラーが返る。（`preflight_run` で "SCTP port publishing is not supported on Apple container" を送出。wbtest「Apple rejects SCTP port publication」PASS）
- [x] Given Apple runtime と host port 0（`with_exposed_port`）, when `start` する, then run 前に明示エラーになる。（wbtest「Apple rejects an ephemeral host port」PASS）
- [x] Given 同一 container port の重複 mapping（Docker / Apple 双方）, when `start` する, then 片方が黙って消えず明示エラーになる。（wbtest「duplicate container ports are rejected on both runtimes」PASS。同 host port 重複も両 runtime で拒否）
- [x] Given capability 表で「未確認」の設定（例: Apple の `--network`）, when `start` する, then 引数へ黙って渡さず明示エラーになる（表の許可根拠がある項目だけ適用）。（`--network` / `--platform` / `--user` / `--mount` / `--read-only` を Apple で明示拒否。wbtest「unverified Apple settings are refused before spawning」PASS）
- [x] Given 既存 smoke と同じ設定, when `build_run_args` で引数を組み立てる, then 既存の期待 argv（[commands_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands_wbtest.mbt) / [image_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image_wbtest.mbt) の固定）を変えない。（0001 で追加された `--name` / `--label` は維持しつつ、golden argv テスト PASS）
- [x] Given runtime 別の負の契約テスト, when `moon test --target native` を実行する, then PASS する。（34 件 PASS。`build_run_args` は純粋関数のため spawn なしで拒否を検証）

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- `commands_wbtest.mbt` / `image_wbtest.mbt` に runtime × 設定の拒否契約（negative テスト）を追加する。`build_run_args` は純粋関数なので、spawn なしで「副作用前に拒否される」ことを検証できる。
- Apple の対応可否確認（`--network` / `--mount` / `--platform`）は 0002 の実機セッションで `container run --help` と実 run を行い、結果を capability 表へ反映する。実機が無い間は「未確認」を維持し、「未実行」と記録する。
- Docker 実機は CI の docker ジョブで既存 `moon run smoke --target native` が通ることを確認する（拒否しすぎの回帰検出）。

## リスク

- capability 表の判定ミスで本来使える設定を拒否する → 適用の根拠（CLI help / 実機確認 / upstream 実装）が無い項目は「未確認」に留め、勝手に許可しない。
- 既存の期待 argv を変えて回帰を隠す → 成功パスの argv をゴールデンとして維持し、テストで固定する。
- direct API 側との二重管理 → 0019 の移行方針で同じ表を参照する形にし、重複定義を避ける。
- 実機が無いと未確認項目が残る → 0002 と同一セッションで確認し、本 issue の検証計画に紐づける。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [CHANGE] CLI adapter で runtime 非対応・未確認の設定を副作用前に明示拒否する

## 注記

- 2026-10-17: 実装着手: capability.mbt に runtime×設定の preflight 判定を集約し、Apple 未確認設定は明示拒否する
- 2026-10-17: 実装完了: `capability.mbt` に `preflight_run` を新設し、`build_run_args` の検証を集約。Apple で未確認の `--network` / `--platform` / `--user` / `--mount` / `--read-only` は明示拒否（実機確認は 0002 のセッションで行い、確認済み項目へ随時格上げ）。Apple で適用としたのは `--name` / cmd / `--entrypoint` / `--workdir` / `--env` / `--label` / 固定 `--publish`(tcp,udp) / log・duration 系 WaitFor で、smoke_apple の argv と upstream CLI 対応を根拠に採用。`container run --label` は 0001 の所有 label 伝播に必須のため、0002 で実機確認すること。host port の重複拒否は両 runtime に追加。検証: `moon check --target native --deny-warn` PASS、`moon test --target native` 34 件 PASS。Docker 実機回帰（smoke）は daemon が必要で未実行（CI docker ジョブで確認）。
- upstream 参照: `linux_unsupported_request_reason`（async_runner.rs）、`reject_sctp_ports` / `normalize_platform` / `allocate_unique_free_host_port`（container_cfg.rs）、`reject_duplicate_mapped_ports`（containers/request.rs）。
- 0005 が本 issue の拒否契約を回帰テストとして固定し、0002 の実機セッションで未確認項目を確定する。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-10-17: 実装着手: capability.mbt に runtime×設定の preflight 判定を集約し、Apple 未確認設定は明示拒否する
- 2026-10-17: capability.mbt の preflight_run に検証を集約し Apple 未確認設定を明示拒否。34 tests PASS。Docker 実機 smoke は daemon 必須のため未実行（CI で確認）
