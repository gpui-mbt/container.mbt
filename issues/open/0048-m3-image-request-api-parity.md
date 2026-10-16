# [P1 / M3] ImageExt・ContainerRequest の override 契約を整える

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 の GenericImage mutable builder は upstream の Image と ContainerRequest の二層設計とは異なる。

## 実装範囲

- name/tag/cmd/env/labels/ready_conditions の override 順序を固定
- with_labels, with_ready_conditions 等の API 差分を整理
- builder コピーと container snapshot の境界を統一

## 完了条件

- [ ] 二重 override で last-wins が一致
- [ ] start 後の builder 変更は既存 Container に影響しない
- [ ] 既存 MoonBit 使用者の API が壊れない

## 検証計画（未実行）

- [ ] upstream request unit 対応 MoonBit wbtest と consumer compile
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `image.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt))
- `src/core/containers/request.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs))
- `src/core/image/image_ext.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
