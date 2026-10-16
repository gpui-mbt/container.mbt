# [P2 / M3] pinned upstream からの API/挙動 drift を追跡する

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M3
Depends on: [0050](./0050-m3-conformance-oracle.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

pinned upstream commit（`f68ba1ffed67`）と新 HEAD の差分を定期的に比較し、追加 API / バグ修正 / 非互換変更を分離して issue 化し、source revision を明記して無批判に取り込まない手順を定着させる。

## 背景

- 参照元は 2026-10-07 の `f68ba1ffed67` に固定されている（[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) 3 行、[README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md) の "Provenance and license"）。
- upstream は develop ブランチで更新が続く（[CHANGES.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/CHANGES.md) の develop 節に `with_kernel` 追加の記録がある。[src/lib.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/lib.rs) のプラットフォーム差も revision で変化し得る）。
- [issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) の運用ルール 6 は「upstream の revision を更新する時は関連 Issue と conformance fixture に根拠を残す」と定める。
- 0050 の conformance は固定 revision を oracle にするため、revision 更新時の扱いを先に定める必要がある。

## 問題

- 差分の確認手順が暗黙知で、見落としや無批判な取り込みの余地がある。
- 追加 API / バグ修正 / 非互換変更が区別されずに issue へ混ざる。
- どの source revision で parity を判定したかが fixture / issue に残らない場合がある。
- 0050 の fixture が旧 revision のまま新しい upstream と比較されると、判定が混在する。

## 目標

- pinned SHA と新 HEAD の差分比較手順（コマンド・観点・記録先）が文書化される。
- 差分は追加 API / バグ修正 / 非互換変更 / 未対応 / 該当なしに分類され、それぞれ issue / fixture / docs へ反映される。
- 各 issue / fixture が単一の upstream revision を参照し、複数 revision が混ざらない。
- 非互換変更は承認なく採用されない。

## 対象外

- 新しい revision の採用そのもの（本 issue は手順と棚卸し。採否は別途承認と専用 issue）。
- fixture の実装（0050）。本 issue は revision の扱いだけを定める。
- upstream 側へのフィードバック（本 port は独立実装）。
- CI への組み込み（0052）。定期実行するかは 0052 と協議する。

## 提案する方針

- 手順を docs の節として書く（docs/PORTING.md への追記か新規 docs かは実装時に決定）。
  1. 現行 pin `f68ba1ffed67` と upstream develop HEAD の差分を取得する（GitHub の compare 画面、または pinned checkout での `git log` / `git diff`。実行可能な方法を手順に固定する）。
  2. 差分を API 面（公開シグネチャ）と挙動面（テスト / CHANGES.md / docs）に分ける。
  3. 分類表に落とす: `[ADD]` API 追加 / `[FIX]` バグ修正 / `[CHANGE]` 非互換 / `[UPDATE]` その他 / 未対応（本 port では扱わないと判断したもの。理由を残す）/ 該当なし。
  4. 影響する担当 issue を特定し、必要なら新規 issue を立てる。revision を根拠にする issue は Upstream baseline と fixture の revision 記録を同時に更新し、根拠（compare URL / 日付 / 新 SHA）を残す（運用ルール 6）。
  5. 0050 の fixture は revision ごとに結果を分けて記録し、混在させない。
- 棚卸しのトリガー（upstream のリリース / CHANGES.md の新節、または定期的な時期）と担当を issue の運用として記録する。具体的な頻度は実装時に決める。
- 非互換変更の採用は「専用 issue + 承認 + 既存呼び出しの移行計画」を条件とし、既存実装へ直接混ぜない。
- 差分に機密前提の変更がある場合は 0016 / 0049 と整合を確認してから扱う。

## 受け入れ条件

- [ ] Given pinned SHA と upstream HEAD, when 比較手順を実行する, then 差分一覧と分類の記録が残る。
- [ ] Given 差分に追加 API がある, when 対応を探す, then 既存 issue に紐づくか新規 issue が起票され、単一 revision を参照する。
- [ ] Given 差分に非互換変更がある, when 採用を判断する, then 承認なしに既存 issue / 実装へ取り込まれない。
- [ ] Given 0050 の fixture, when revision を確認する, then 1 fixture 内に複数 revision が混在しない。
- [ ] Given revision 更新を実施する, when 記録する, then compare URL / 日付 / 新 SHA と更新した fixture の結果が残る。
- [ ] Given 更新後の表記, when 確認する, then docs/PORTING.md / README / issue の Upstream baseline が同一 revision で一致する。

## テスト計画

- 本 issue は手順整備。実証として 1 回、現行 pin と upstream develop の差分比較を実行し、分類結果を記録する（compare 画面 / `git log` / `git diff` のうち実行できる方法）。
- 差分に基づく実装変更が生じた場合は `moon check --target native --deny-warn` / `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 0050 の fixture 更新を伴う場合は fixture を再実行し、revision ごとに結果を記録する。Apple 実機が必要なものは「未実行」と理由を記録する。
- 手動レビューでもよいが、観点（API / 挙動 / テスト / CHANGES）をチェックリスト化して抜けを防ぐ。

## リスク

- 差分の見落とし。観点チェックリストと公開シンボルの差分抽出を手順に含める。
- 旧 revision の fixture 結果と新 revision の結果を混ぜて誤判定する。fixture の revision 列を必須にする。
- 非互換変更を早期に採用して既存利用者を壊す。採用は専用 issue と承認を条件にする。
- 棚卸しが行われず pin が古くなる。トリガーを運用手順に明記し、0050 の oracle 表記と連動させる。
- ロールバック: 手順文書と fixture 記録の追加のみ。pin を変えない限り実装への影響はない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)、[src/lib.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/lib.rs)、[CHANGES.md](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/CHANGES.md)。
- 関連: 0050（revision ごとの fixture 記録）、0052（証跡と定期実行の分担）、issues/README.md の運用ルール 6。
- upstream の差分確認は読み取り専用で行い、このリポジトリの作業ツリーへ upstream の変更を直接 checkout しない。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
