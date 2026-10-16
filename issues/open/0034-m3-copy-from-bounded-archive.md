# [P1 / M3] copy_file_from でファイルを安全に取り出す

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0011](./0011-m1-docker-inspect-stop-rm-wait.md), [0007](./0007-m1-docker-http-framing-parser.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream は Linux/macOS の copy_file_from を提供するが M0 は未移植。

## 実装範囲

- GET archive/必要な XPC copy を公開 API へ統合
- tar 内単一 file/dir の扱いを定義
- 64 MiB 超過時は切り詰めず失敗にする

## 完了条件

- [ ] ファイル内容の bytes と権限の扱いが明記
- [ ] 不存在 container と path を区別
- [ ] エラー時に部分データを正常扱いしない

## 検証計画（未実行）

- [ ] Docker/macOS テスト、missing path / large fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/copy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs))
- `src/core/client/docker_tar.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
