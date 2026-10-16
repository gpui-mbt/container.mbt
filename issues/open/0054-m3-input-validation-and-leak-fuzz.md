# [P1 / M3] argv/JSON/path/ログの不正入力と資源リークを系統検証

- Status: open
- Created: 2026-10-16
- Priority: P1
- Milestone: M3
- Depends on: [0010](./0010-m1-docker-create-start.md), [0024](./0024-m2-xpc-protocol-contract.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

外部入力を runtime に渡す境界が増えると shell 注入・encoding 破綻・FD leak のリスクがある。

## 実装範囲

- 文字列 argv の配列渡し維持、shell evaluation 不使用
- 改行/NUL/非 UTF-8/大きな出力/負値・overflow を網羅
- 失敗中断でも socket/FD/process が解放されることを検証

## 完了条件

- [ ] 入力により任意ホストコマンドが実行されない
- [ ] 不正バイト列で正常成功にならない
- [ ] 長時間反復で FD/メモリが単調増加しない

## 検証計画（未実行）

- [ ] MoonBit unit/property test + Docker/Apple fault E2E
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `commands.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands.mbt))
- `runtime.mbt` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt))
- `src/core/util.rs` ([upstream](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/util.rs))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
