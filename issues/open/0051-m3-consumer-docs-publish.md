# [P2 / M3] Mooncakes consumer から使える公開 API・文書・配布

- Status: open
- Created: 2026-10-16
- Priority: P2
- Milestone: M3
- Depends on: [0048](./0048-m3-image-request-api-parity.md)
- Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 背景・目的

リポジトリ内 unit test だけでは外部 MoonBit アプリから API が使える保証がない。

## 実装範囲

- moon.mod/package を整理して mooncakes publish の条件を定義
- Docker/Apple 例とサポート表を README に追加
- 最小依存 sample を別 consumer として実行

## 完了条件

- [ ] 外部 sample が依存解決・build・start/rm できる
- [ ] supported OS/version と非互換点を公開
- [ ] 公開はバージョン/承認後に行う

## 検証計画（未実行）

- [ ] moon check/test/build --target native; 独立 consumer smoke
- [ ] 変更が MoonBit コードを含む場合は `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- [ ] 必要な実ランタイムが使えない場合は対応 OS の E2E を「未実行」と明記し、擬似テストだけで完了にしない。

## 主な参照

- `moon.mod` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/moon.mod))
- `README.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md))
- `docs/PORTING.md` ([MoonBit 作業ブランチ](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md))

関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
