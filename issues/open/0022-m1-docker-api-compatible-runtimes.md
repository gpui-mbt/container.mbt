# [P2 / M1] Podman 等 Engine API 互換環境の互換境界を記録

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M1
- Depends on: [0020](./0020-m1-linux-native-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は Linux で Docker Engine API 互換を想定するが挙動差があり得る。

## 実装範囲

- Podman rootless・Docker rootless の socket と API 差を調査
- 未確認を対応済みとせず capability matrix に記録
- 非対応 operation を診断する

## 完了条件

- [ ] 少なくとも Docker Engine 基準が維持される
- [ ] 互換ランタイムの PASS/未実行/FAIL が明示
- [ ] rootless 特有の権限制約を記録

## 検証計画（未実行）

- [ ] Podman が利用可能な Linux runner でオプション E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
