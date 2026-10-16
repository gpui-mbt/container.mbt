# [P1 / M3] hostname・ExtraHost・network を API と実行経路に追加

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream ContainerRequest は hostname/hosts/network を持つが M0 は network 名だけ。

## 実装範囲

- hostname/ExtraHost/host-gateway を builder に追加
- Docker HostConfig と XPC 対応を分離
- 作成済 network の参照/未存在の失敗を扱う

## 完了条件

- [ ] /etc/hosts の解決をコンテナ内で確認
- [ ] host gateway が OS ごとの仕様に沿う
- [ ] ネットワークの自動作成は対応範囲を明記

## 検証計画（未実行）

- [ ] Docker network fixture / Apple host gateway real E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/containers/request.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs))
- `src/core/host.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/host.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
