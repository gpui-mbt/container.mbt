# [P1 / M1] Linux でプロセスクラッシュ後の残存検出と限定回収

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0020](./0020-m1-linux-native-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

通常の errdefer はプロセス kill 後に動かず、テストコンテナが残る可能性がある。

## 実装範囲

- 子プロセスで起動後 SIGKILL する実験 fixture を構築
- 所有 label と孤児識別を定義
- 既存容器に影響しない限定 cleanup と失敗診断

## 完了条件

- [ ] kill -9 後の孤児が検出・回収される
- [ ] 外部で作成したコンテナは残る
- [ ] 再実行しても誤削除しない

## 検証計画（未実行）

- [ ] Linux Docker 実プロセス kill E2E。破壊対象を実験ラベルに限定
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/watchdog.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/watchdog.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
