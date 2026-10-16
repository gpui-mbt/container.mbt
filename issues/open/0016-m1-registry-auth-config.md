# [P1 / M1] Docker registry 認証と秘密情報保護

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0009](./0009-m1-native-image-pull.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は auths の静的資格情報を利用するが MoonBit 版は未実装。

## 実装範囲

- DOCKER_AUTH_CONFIG > DOCKER_CONFIG/config.json > ~/.docker/config.json の優先順
- Docker Hub key 正規化と identitytoken/auth の処理
- ヘッダ・ログ・例外に認証情報を出さない

## 完了条件

- [ ] 公開 image は匿名 pull 可能
- [ ] private registry auth の構築が fixture 一致
- [ ] credential helper 非対応を明記

## 検証計画（未実行）

- [ ] 環境変数隔離 unit / 模擬レジストリ認証 / secrets 非漏出テスト
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/registry_auth.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/registry_auth.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
