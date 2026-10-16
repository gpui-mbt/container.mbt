# [P1 / M1] Docker stdout/stderr の follow/attach と有界取得

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M1
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

CLI の logs() は一回取得であり upstream のストリーム継続取得と異なる。

## 実装範囲

- Docker logs API の follow/stdout/stderr と frame parsing
- 読み取り中の停止/削除を扱う
- 64 MiB 境界と consumer cancel を定義

## 完了条件

- [ ] 長いログを失わず配信し、無限にメモリを蓄積しない
- [ ] stop/rm 後に購読タスクが止まる
- [ ] stdout と stderr の混線がない

## 検証計画（未実行）

- [ ] Docker log stream E2E と小チャンク/早期 EOF unit
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/client/docker_log_stream.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_log_stream.rs))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
