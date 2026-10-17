# [P0 / M0] Apple Silicon 実機で M0 CLI smoke を完走する

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M0
Depends on: [0001](./0001-m0-run-failure-orphan-cleanup.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

物理 Apple Silicon Mac（macOS 26 以降）で `smoke_apple` の CLI ライフサイクル E2E を完走し、OS・architecture・`container system version`・実行ログ・前後のコンテナ一覧を証跡として保存する。Linux Docker CI の green や macOS runner の compile 成功では代替しない。

## 背景

- [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) は現状 **NOT RUN** で、物理ホストでの Apple Container 受入をマージゲートに含めている。
- [smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt) は固有 name で `alpine:3.20` を `run --detach` し、`moonbit-apple-ready` の stdout 待ち、固定ポートの取得、`exec` / `logs` / `stop` / `delete --force`、`container inspect` による残存確認を実装済み。成功時は `Apple Container lifecycle E2E PASS` を出力する。
- GitHub ホストの `macos-26` ARM64 runner はネスト仮想化がサポートされないため、物理 Mac の代替にならない（docs/APPLE_E2E.md）。
- 0001 が CLI run 失敗時の orphan 回収を追加する。本 issue は 0001 の完了を前提に、その失敗経路も実機で確認する。

## 問題

- `moon run smoke_apple --target native` は物理 Mac で一度も実行されておらず、M0 の Apple Container 受入証跡が存在しない。
- CI の Linux Docker ジョブと macOS compile ジョブは Apple Container runtime の起動を検証しない（[issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) ルール 4）。
- 失敗時のコンテナ残存（0001 の対象）が実機で確認されていない。

## 目標

- 物理 Apple Silicon Mac で `smoke_apple` が exit code 0 で `Apple Container lifecycle E2E PASS` を出力する。
- OS version / architecture / `container system version` / コマンドログ / 実行前後の `container list --all` を証跡として保存する。
- 終了後にテストコンテナが残存しない。
- 0001 の失敗経路（run が ID を返す前に失敗するケース）も実機で確認する。

## 対象外

- ホストからの TCP 往復検証（0003 が担当。本 issue の証跡に 0003 の結果を加えてよい）。
- 非対応設定の capability 表（0004）と回帰テストの整備（0005）。
- Apple Container XPC（0023–0032、M2）。
- Linux Docker Engine 直結（0006–0022、M1）。
- Intel Mac や仮想化ゲストの macOS（docs/APPLE_E2E.md が物理 Apple Silicon Mac と等価でないと明記）。

## 提案する方針

- [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の Run on the host 手順をそのまま実行する: `moon update` → `moon check --target native --deny-warn` → `moon test --target native` → `moon run smoke_apple --target native` → `container list --all`。
- 前提を確認する: `uname -m` が `arm64`、`sw_vers -productVersion` が 26.x 以降、`container system start` 完了済み、`lsof -nP -iTCP:18080 -sTCP:LISTEN` が無応答。
- smoke が落ちた場合は失敗経路を実機で切り分け、[smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt) またはライブラリ本体を修正する。ライブラリの修正である場合は回帰テストを 0005 へ追加する。
- 0001 の実装に合わせて run 失敗ケース（例: 存在しない `--entrypoint` で run が ID を返す前に失敗するケース）を `smoke_apple` に追加し、残存ゼロと無関係コンテナの生存を確認する。追加方法は 0001 のテスト設計に合わせる（本 issue で関数名を断定しない）。
- 証跡は PR コメントまたは artifact に、実行したコマンドと生の出力をそのまま残す。`container list --all` は実行前・実行後・終了後の 3 時点を取る。
- GitHub ホストの macOS runner は compile-only として扱い、E2E PASS と記録しない。

## 受け入れ条件

- [x] Given 物理 Apple Silicon Mac（macOS 26 以降、`container system start` 完了）, when `uname -m` / `sw_vers -productVersion` / `container system version` を実行する, then `arm64` / 26.x 以降 / container version が記録される。**PASS** — `arm64`, macOS 26.5.2, container 0.12.3（`docs/evidence/2026-10-17-apple-m0/environment.txt`）。
- [x] Given 18080 が空いている, when `moon run smoke_apple --target native` を実行する, then exit code 0 で `Apple Container lifecycle E2E PASS` が出力される。**PASS（固定ポートは 18081）** — 18080 はユーザープロセス `madobe-sh` が LISTEN 中のため未実行。同じ固定 `18081:80/tcp` 経路で TCP 到達込みの PASS を取得（`smoke.log`）。
- [x] Given `moon run smoke_apple` が正常終了した, when `container list --all` を確認する, then テストコンテナが残存しない。**PASS** — 実行後一覧は空（`after.txt`）。
- [x] Given 0001 の run 失敗ケース, when 実機で実行する, then 生成した name のコンテナが残らず、無関係な既存コンテナが削除されない。**PASS** — 不正 entrypoint の `start_cli` が失敗し、当該名は inspect 不在、foreign コンテナは存続（smoke 内 assert）。
- [x] Given 変更が MoonBit コードを含む, when `moon check --target native --deny-warn` と `moon test --target native` を実行する, then PASS する。**PASS** — 270 tests PASS（macOS 修正後）。
- [x] Given 実行環境が VM または GitHub ホスト runner のみ, then その結果を Apple E2E PASS として記録しない（「未実行」と明記する）。**PASS** — 物理 Apple Silicon で実行。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 物理 Mac で `moon run smoke_apple --target native` を実行し、出力・exit code・実行前後の `container list --all` を証跡として保存する。証跡には OS / arch / `container system version` / 実行ログを含める。
- 0003 の TCP 到達検証を同一セッションで実施し、結果を本 issue の証跡へ含める。
- 物理 Mac が使えない間は本 issue を「未実行」と記録し、Linux Docker や macOS compile-only で読み替えない（issues/README.md ルール 4）。
- テストの掃除は `smoke_apple` の固有 name と `container inspect` 確認に限定し、ユーザー所有コンテナを削除しない（同ルール 5）。

## リスク

- 物理 Mac を確保できずマージゲートが未達のままになる → 0003 とまとめて 1 セッションで実行し、未実行理由を記録して Draft を維持する。
- Apple Container の version 差で smoke が落ちる → `container system version` を証跡に残し、挙動差は 0004 の capability 表と 0003 のエラー分類へ反映する。
- ローカルネットワーク権限の初回確認が対話になる → 事前に手動許可し、失敗時は権限要因として記録する（0003 と共通）。
- 実機のユーザー所有コンテナを誤削除する → smoke は固有 name だけを操作し、掃除も同じ name に限定する。

## 変更履歴

`CHANGES.md` impact: no

判断理由: 実機での受入実行と証跡記録が中心で、利用者に見える API・挙動を変えない。ライブラリ修正が必要になった場合は該当修正の issue で扱う。

## 注記

- 証跡要件: OS version、hardware architecture、`container system version`、コマンドログ、最終 `container list --all`（docs/APPLE_E2E.md）。
- マージゲート: Linux CI green + 独立 approve 相当レビュー + 物理ホスト Apple テスト green + startup cleanup blocker の解消（docs/APPLE_E2E.md）。
- 関連: [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md)、[smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt)、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 0003 が TCP 到達を、0004 が実機で確認した capability 差を、0005 が回帰テストを引き受ける。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-10-17: 実装・実機実行。`smoke_apple` を HTTP fixture（BusyBox nc）+ ホスト TCP `GET /`、固定ポート占有時の明示エラー、不正 entrypoint の run 失敗経路、foreign コンテナ存続確認へ拡張。`name_in_use_via` / cleanup の inspect 判定を Apple CLI の「存在しないと exit 0 + `[]`」に合わせて修正。`unix_transport.c` の macOS 対応と errno 分類も追加。物理 Apple Silicon / macOS 26.5.2 / container 0.12.3 で `Apple Container lifecycle E2E PASS`、`container list --all` 残存ゼロ。18080 は既存ユーザー listener のため 18081 で採証（18080 の占有時エラーは別途 PASS）。証跡: `docs/evidence/2026-10-17-apple-m0/`。

追記: 2026-10-17 に Apple Container 1.5.0 へ更新後、同じ smoke を再実行して PASS（M0 CLI / TCP 18081）。1.5.0 の環境証跡は `docs/evidence/2026-10-17-apple-xpc-1.5.0/`。
