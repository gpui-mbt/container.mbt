# [P0 / M1] Node/Rust に依存しない Docker Unix socket transport

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: なし
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

M0 は docker CLI を子プロセス実行するが、upstream Linux は Docker Engine API に直接接続する。

## 実装範囲

- MoonBit native から Unix domain socket 接続を実現
- socket path とリクエストを構造化する
- 接続・読み書き・EOF・取消の資源所有を明確にする

## 完了条件

- [ ] docker CLI なしで GET /_ping に到達
- [ ] 存在しない socket・権限拒否を別エラーとして返す
- [ ] FD が成功/失敗とも閉じる

## 検証計画（未実行）

- [ ] Unix socket mock と Linux Docker daemon backed E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
