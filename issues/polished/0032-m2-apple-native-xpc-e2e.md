# [P0 / M2] macOS 26 Apple Silicon の XPC native 受入試験

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: [0026](./0026-m2-xpc-create-start.md), [0027](./0027-m2-xpc-stop-remove.md), [0028](./0028-m2-xpc-exec.md), [0029](./0029-m2-xpc-logs-fd-ownership.md), [0030](./0030-m2-xpc-ports-network-inspect.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

物理 Apple Silicon（macOS 26+）で、`container` CLI バイナリに依存しない XPC native 経路の pull → create → exec → logs → stop → delete を完走し、FD / ポート / cleanup の残留ゼロを証跡付きで受入れる。

## 背景

- [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) は M0 の CLI smoke 受入で、Status は NOT RUN。物理 Apple Silicon・macOS 26+ を要求し、GitHub-hosted macOS runner は nested virtualization 非対応のため実機の代替にできないと明記している。
- 現行 [smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt) は `image.start(@container.AppleContainer)` の CLI adapter 経由であり、XPC native の検証ではない。upstream は macOS 実装を XPC（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）で行い、CLI に依存しない。
- 0026–0031 が XPC の create/start、stop/remove、exec、logs、ports、mounts を実装し、本 issue がその統合受入になる。
- README と [issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) の運用ルール 3・4 は、M2 を Linux とは別に受入れ、物理 Mac E2E を VM / CI compile-only で代替しないと定める。

## 問題

- XPC native の E2E 実行手段・出力マーカー・証跡項目（FD / ポート / cleanup）が未定義。
- CLI smoke（M0）と XPC 受入が混同される余地があり、実行 / 未実行の記録も分かれていない。

## 目標

- 物理 Apple Silicon で XPC native の lifecycle が完走する。
- `container` CLI を起動していないことをログと実装で示せる。
- FD 残留ゼロ、公開ポートの到達、orphan ゼロの証跡が残る。
- 実行 / 未実行と PASS / FAIL が明示的に記録される。
- 証跡の様式が docs/APPLE_E2E.md と一致する。

## 対象外

- M0 CLI smoke の受入（0002 / 0003）。本 issue は XPC native 専用。
- Linux Docker E2E（0020）と CI プラットフォームマトリクス（0052）。ただし本 issue の証跡は 0052 の実機証跡として参照させる。
- 未実装の readiness（healthcheck / exit / HTTP）の受入。実装済み機能のみを対象にする（0036–0039 完了後に必要なら節を追加）。

## 提案する方針

- XPC native の smoke 実行物を追加する（例: `smoke_xpc/main.mbt`（新規、名前は実装詳細として変更可））。`@shell` / `@process` で `container` バイナリを起動しない構成にし、実行ログでも spawn がないことを確認する。
- シナリオ: image pull → create → start → exec（stdout / stderr / exit code）→ logs（stdout と bootlog の区別）→ stop → delete。0026 の rollback を確認する故障注入（不正 config の create 拒否、readiness 失敗時の回収）も含める。
- 証跡項目: `uname -m`、`sw_vers -productVersion`、Apple container 側のバージョン、実行ログ全文、操作前後のコンテナ一覧（XPC の `containerList` 相当）、FD 数の比較（0029）、hostPort=0 の公開ポートとホストからの到達（0030）、delete 後の当該 ID 不在。docs/APPLE_E2E.md の「Execution environment / Run on the host / Boundaries」の構成に倣った XPC 節を追記し、既存の M0 CLI 節は書き換えない。
- 受入マーカーは M0 CLI smoke の `Apple Container lifecycle E2E PASS` と別の文字列にする（例: `Apple XPC lifecycle E2E PASS`。名称は実装時に決定する）。
- 物理 Mac が使えない間は「未実行」と記録する。CI のビルド / テスト成功は compile-only として区別し、実機 PASS と表現しない。

## 受け入れ条件

- [ ] Given macOS 26+ の物理 Apple Silicon（VM ではない）, when XPC native smoke を実行する, then pull → create → exec → logs → stop → delete が完走し、受入マーカーと exit 0 を出力する。
- [ ] 実行プロセスが `container` CLI を spawn していない（argv とログで確認）。
- [ ] exec の stdout / stderr / exit code が期待どおりで、logs が stdout と bootlog を混同しない。
- [ ] hostPort=0 の公開ポートへ実際にホストから接続できる。
- [ ] delete 後に当該 name / ID のコンテナが残らず、FD 数が実行前と等しい。
- [ ] 実行の前後で無関係な既存コンテナを変更しない（固有 name / label のみ操作）。
- [ ] 証跡（環境情報、実行ログ、一覧、FD 数、ポート確認）が docs/APPLE_E2E.md の様式に沿って保存される。
- [ ] 実行できない場合、「未実行」と理由が記録され、CI green を実機 PASS と表現しない。

## テスト計画

- 前提: 0026–0031 の完了。`moon check --target native --deny-warn` と `moon test --target native` は各変更で実行し、PASS / FAIL / 未実行を記録する。
- 実機手順（未実行。物理 Mac が必要）: docs/APPLE_E2E.md の環境節に倣い、`uname -m` = arm64、`sw_vers -productVersion` = 26.x、Apple container の version / status を記録してから XPC smoke を実行し、最後にコンテナ一覧を取得する。手順と結果は XPC 節として追記する。
- 故障注入: 不正 config、readiness 失敗、exec の wait 失敗を実機で実行し、回収と FD 閉鎖を確認する。
- 通常 CI（ubuntu）は XPC の compile-only ゲートとして扱い、本 issue の完了条件にはならない。

## リスク

- 実機が使えず完了できない: 依存 issue 完了後もブロックしたまま「未実行」を維持し、CI で代替しない。
- macOS / Apple container のバージョン差: 環境証跡を必須にし、drift は 0053 で追跡する。
- テストがユーザー所有コンテナを壊す: 固有 name / label と明示 delete のみを使う（運用ルール 5）。
- M0 CLI smoke との混同: 出力マーカーと docs の節を分離する。
- ロールバック: 新規 smoke 実行物に閉じ、プロダクションコードの契約を変更しない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 主な参照: [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md)、[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)。
- 証跡は 0029（FD 数）、0030（ポート）、0027（cleanup）の各確認を統合した platform acceptance として保存し、0052 の CI 区別とも整合させる。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。M0 CLI 受入（0002）と XPC 受入（本 issue）は別ゲートとして扱う。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
