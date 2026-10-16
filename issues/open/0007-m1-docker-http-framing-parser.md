# [P0 / M1] Docker HTTP/1.1 応答・chunked・stream decoder を実装

- Status: open
- Created: 2026-10-16
- Priority: P0
- Milestone: M1
- Depends on: [0006](./0006-m1-docker-unix-socket-transport.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

Docker Engine API は単純な一括文字列出力ではなく chunked/streaming response を返す。

## 実装範囲

- status/header/content-length/chunked/EOF を正しく処理
- 境界で分割された入力・異常フレームを処理
- 本文サイズと時間を上限付きで読む

## 完了条件

- [ ] 分割パケットでも 1 つの応答になる
- [ ] 壊れた chunk や矛盾した長さは fail closed
- [ ] 64 MiB を超える一括取得を成功扱いしない

## 検証計画（未実行）

- [ ] 固定バイト列を各境界で切る parser test と daemon E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/http_decode.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/http_decode.rs))
- `src/core/client/docker_client.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
