# [P1 / M3] privileged・capability・shm・init 等を移植

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream ImageExt には with_privileged/cap_add/cap_drop/shm_size/init 等があり M0 にない。

## 実装範囲

- 安全な option 型と validation を実装
- Linux Docker HostConfig に反映
- Mac 側非対応なら明示エラーにする

## 完了条件

- [ ] cap add/drop の実効値を inspect で確認
- [ ] 無効な値/サイズは起動前に fail
- [ ] privileged は暗黙 true にしない

## 検証計画（未実行）

- [ ] Docker inspect E2E / capability-negative unit
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/image/image_ext.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs))
- `src/core/client/container_cfg.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
