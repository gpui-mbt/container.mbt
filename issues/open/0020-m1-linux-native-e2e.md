# [P0 / M1] Linux daemon 直結の起動から削除までの E2E

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0010](./0010-m1-docker-create-start.md), [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0012](./0012-m1-docker-exec-attach.md), [0013](./0013-m1-docker-log-stream.md), [0014](./0014-m1-dynamic-published-ports.md), [0018](./0018-m1-engine-deadline-cancel.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Docker CLI smoke の成功は Docker Engine transport 完了を証明しない。

## 実装範囲

- Unix socket のみを用いた pull→create→start→wait→exec→logs→inspect→stop→rm
- テストの container name に固有 prefix を付与
- 終了後残存ゼロを確認

## 完了条件

- [ ] Docker CLI が PATH にない環境でもテストが通る
- [ ] 一連の各 API 呼出の証跡が残る
- [ ] 失敗時も cleanup

## 検証計画（未実行）

- [ ] CI の Linux Docker daemon-backed native E2E; moon check/test/build --target native
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `smoke/main.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke/main.mbt))
- `.github/workflows/ci.yml` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
