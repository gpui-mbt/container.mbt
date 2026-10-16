# [P1 / M0] Apple CLI 固定 published port の TCP 到達を検証

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M0
- Depends on: [0002](./0002-m0-apple-cli-physical-e2e.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

現行 smoke_apple は固定ポート番号の取得のみでホストからの通信成功を検証しない。

## 実装範囲

- 固有ポートで HTTP/TCP 応答 fixture を起動
- ホストから実際に接続し内容と切断挙動を検査
- 使用中ポートや Local Network Privacy 拒否を区別

## 完了条件

- [ ] 名前解決ではなく TCP 往復を証拠として残す
- [ ] port 占有時はスキップではなく明示した環境エラー
- [ ] 実験後にテストコンテナだけが消える

## 検証計画（未実行）

- [ ] Apple Silicon 実機 E2E、手動の TCP 接続・HTTP ステータス確認
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `smoke_apple/main.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt))
- `src/core/ports.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
