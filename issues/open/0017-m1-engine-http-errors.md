# [P1 / M1] Docker API ステータスと失敗分類を実装

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 は CLI exit code と stderr の文字列だけで失敗を扱う。

## 実装範囲

- 401/403/404/409/5xx を操作文脈付きに分類
- image-not-found と container-not-found と path-not-found を分離
- HTTP body は容量上限を適用

## 完了条件

- [ ] 同じ 404 でも削除対象・pull 対象で正しく判別
- [ ] 失敗時に resource leak がない
- [ ] ユーザーに資格情報を漏らさない

## 検証計画（未実行）

- [ ] fake Engine 各 HTTP status と Docker 不在 ID E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/error.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/error.rs))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
