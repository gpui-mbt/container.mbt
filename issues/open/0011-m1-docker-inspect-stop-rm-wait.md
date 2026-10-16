# [P0 / M1] Docker inspect/stop/rm/wait と冪等 lifecycle を移植

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0010](./0010-m1-docker-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 の Container は CLI の固定操作のみで、Engine 状態取得と stop 終了コードがない。

## 実装範囲

- /containers/{id}/json・/stop・DELETE・/wait を実装
- 既停止/既削除/他者削除を分類
- 停止と削除のタイムアウトを個別に制限

## 完了条件

- [ ] start/stop/rm の再試行が意図せず別コンテナに作用しない
- [ ] stop→rm 後の inspect は not found
- [ ] force remove の適用条件が明示される

## 検証計画（未実行）

- [ ] Docker lifecycle E2E と異常応答 stub
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
