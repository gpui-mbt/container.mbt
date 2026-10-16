# [P1 / M3] Linux archive API による with_copy_to の起動前投入

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md), [0011](./0011-m1-docker-inspect-stop-rm-wait.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

upstream Linux は初期プロセス起動前にコピーしたファイルを読める。

## 実装範囲

- create→PUT /containers/{id}/archive→start の順を実装
- ファイル/ディレクトリ/親ディレクトリを処理
- コンテナパス検証とサイズ上限を設ける

## 完了条件

- [ ] init が開始時点で copy-to ファイルを認識
- [ ] 失敗時 start しない
- [ ] 親ディレクトリ不存在を意図通り処理

## 検証計画（未実行）

- [ ] Docker 実機で prestart file read と invalid path fixture
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `src/core/copy.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/copy.rs))
- `src/core/client/docker_tar.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_tar.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
