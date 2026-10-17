# [P1 / M3] ImageExt・ContainerRequest の override 契約を整える

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M3
Depends on: [0010](./0010-m1-docker-create-start.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

upstream の `Image`（記述子）と `ContainerRequest`（起動時 override）の二層を MoonBit の `GenericImage` へ写像し、name / tag / cmd / env / labels / ready_conditions の override 順序と start 時 snapshot の境界を固定する。

## 背景

- upstream は `Image` trait（name / tag / ready_conditions / env_vars / entrypoint / cmd の読み出し）と `ContainerRequest<I>`（`image` に設定を重ねる層）に分かれる（[src/core/containers/request.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs) 29–61 行付近）。
- override の意味論は次のとおり。
  - descriptor は `image_name` / `image_tag` の override が優先（request.rs 207–215 行付近）。
  - cmd は `overridden_cmd` が非空ならそれ、空ならイメージ既定 CMD（request.rs 183–201 行付近）。
  - env はイメージ既定 + request 側を連結し、同名キーは request 勝ち（request.rs 116–127 行付近。`container_cfg.rs` 1945 行付近のテスト）。
  - `with_cmd` は置換、`with_ready_conditions` はリスト全体の置換（後勝ち）、`with_label` / `with_env_var` はキー単位 insert、`with_labels` は extend（キー単位上書き）（[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs) 234–460 行付近）。
- 現行 MoonBit は単一の mutable `GenericImage` で、[image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) の `with_env_var` / `with_label` は既存キーを除去して末尾へ再追加する last-wins 実装（159–182 行付近）。`with_cmd` は `command.copy()` で置換（140–143 行付近）、`with_wait_for` は push で蓄積（211–214 行付近）。
- [runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt) の `start` は mappings と ready_conditions を起動前に copy する（83–85 行付近）。README も "Published mappings are snapshotted when the CLI run starts; later image-builder mutations cannot change the container's reported ports." と境界を文書化している。
- 既存の回帰: [image_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image_wbtest.mbt) の "environment overrides are last-wins" / "command builder snapshots mutable caller arguments"、[commands_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands_wbtest.mbt) の "Docker run command captures an Alpine test fixture"（`A=two` のみを検証）。

## 問題

- `with_name` / `with_tag` に相当する override が無く、`GenericImage::new(name, tag)` の後に descriptor を変更できない。
- upstream の `with_ready_conditions`（リスト置換・後勝ち）に相当する API が無く、現行 `with_wait_for` は蓄積。同名概念の意味論対応表がない。
- `with_labels` のような配列を受ける bulk API がない。
- start 後の builder 変更が Container に影響しない範囲が mappings / conditions に限られ、全項目で統一された snapshot 契約になっていない。
- 同一キーを 2 回 override したときの挙動（値の後勝ち、引数内の出現順）が契約として明文化されていない。

## 目標

- name / tag / cmd / env / labels / ready_conditions の override 順序が明文化され、テストで固定される。
- 二重 override はキー単位 last-wins で upstream と一致し、同一キーは 1 件だけになる。
- start 時の snapshot 境界が「起動に使った値は以後の builder 変更で変わらない」として全項目で成立する。
- 既存 MoonBit 利用者の API（メソッド名・戻り値型・蓄積 / 置換の別）が壊れない。

## 対象外

- エラー分類（0049）。Apple XPC の request 化（0024）。
- mount / port の意味論変更（0044）と hostname / network（0045）。
- `Image` trait をそのまま公開すること。MoonBit では既存 `GenericImage` の拡張として写像する。
- env / label の引数内でのソート順を upstream の BTreeMap と完全一致させること。順序は契約に含めない。

## 提案する方針

- [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt) に追加する（内部表現・名前は実装詳細として変更可）。
  - `with_name(name)` / `with_tag(tag)`: descriptor 用の override。元の `GenericImage::new` の値を保持し、override を優先して `descriptor()` を合成する。未指定時は現行どおり。
  - `with_labels(labels : Array[(String, String)])`: キー単位 last-wins で追加（upstream `with_labels` の extend 相当）。
  - `with_ready_conditions(conditions : Array[WaitFor])`: リスト全体を置換（後勝ち。upstream `with_ready_conditions` 相当）。
- `with_wait_for` は現行の蓄積契約を維持し、置換 / 後勝ちの意味論は `with_ready_conditions` に分離する。これで「既存 API の非破壊」と「upstream との対応」を両立する（意味論の対応表を issue に残す）。
- `with_cmd` は現行の置換契約と配列 copy を維持する。空配列を渡した場合にイメージ既定 CMD へフォールバックする upstream の意味論（`overridden_cmd` が空なら `image.cmd()`）と、CLI adapter で追加入力を渡さない挙動が同じ結果になることを確認する。
- `with_env_var` / `with_label` は現行の「既存キー除去 + 末尾追加」を維持しつつ、同一キーが 1 件だけになることをテストで固定する。引数内のキー順は契約に含めない（upstream の BTreeMap はキー昇順だが Docker / Apple の挙動に差がないことを確認する）。
- start の snapshot: `build_run_args` へ渡した時点の値（command / entrypoint / env / labels / name / ready conditions / mappings / mounts など）を起動呼び出し内のローカルへ copy してから CLI を起動する。現行の mappings / conditions copy を他項目へ広げ、start 後の builder 変更が既存 Container の挙動・再操作へ影響しないことをテストする。Container が保持しない設定は start 呼び出し内のスナップショットで足りる。
- 既存 API のシグネチャは変えない（`with_env_var` / `with_label` / `with_cmd` / `with_container_name` / `with_wait_for`）。変更は追加 API と内部 snapshot に限定する。
- upstream 対応表（override 対象 / upstream の意味論 / MoonBit の対応 / 判定）を fixture として issue または docs に残す。0050 の比較観点に接続する。

## 受け入れ条件

- [x] Given `with_env_var("A", "one")` の後に `with_env_var("A", "two")`, when run 引数を構築する, then `A=two` が 1 回だけ出力される（既存テストの維持）。
- [x] Given `with_label("k", "v1")` の後に `with_labels([("k", "v2")])`, when run 引数を構築する, then `k=v2` が 1 回だけ出力される。
- [x] Given `with_ready_conditions([...])` を 2 回呼ぶ, when start する, then 最後のリストだけが readiness に使われる。
- [x] Given `with_name` / `with_tag` を指定, when `descriptor()` を評価する, then override が優先され、未指定時は `GenericImage::new` の値になる。
- [x] Given start 後に builder へ `with_env_var` / `with_label` / `with_cmd` / `with_wait_for` を追加する, when 既存 Container を操作する, then 既存 Container の挙動が変わらない（mappings の既存テストと同じ契約）。
- [x] Given `with_wait_for` を複数回呼ぶ, when start する, then 現行どおり蓄積され、`with_ready_conditions` とは区別される。
- [x] Given `smoke` / `smoke_apple` を含む既存コード, when ビルド・実行する, then 変更なしでコンパイル・動作する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - [image_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image_wbtest.mbt) / [commands_wbtest.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/commands_wbtest.mbt) に override 順序・snapshot のテストを追加する。upstream `request.rs` / `image_ext.rs` のテスト名との対応表を残す（例: `env_vars_are_folded_with_request_winning_in_init_env`）。
- `moon run smoke --target native` で start 後 mutation の非影響を再確認する（Docker 実機、CI の docker-e2e ジョブ）。
- 0051 の独立 consumer sample が既存 API をそのまま使えることを確認する（0051 と連携）。
- 本 issue は純 MoonBit 層のため実機 E2E は不要。ただし引数が実際に runtime へ渡る確認は smoke で行い、実行不能な確認は「未実行」と記録する。

## リスク

- `with_wait_for` の意味論を置換へ変えると既存呼び出しの readiness が変わる。蓄積の現行契約を維持し、置換は新 API に分離して互換性を守る。
- 引数内のキー順が現行実装（除去 + 末尾追加）で変わる。順序を契約に含めないことをテストと注記で明示し、Docker / Apple で差がないことを確認する。
- start の snapshot 追加でコピーが増え、起動 1 回あたりのメモリ・レイテンシが微増する。対象は起動要求の設定に限定する。
- upstream の `ContainerRequest` 二層を MoonBit の単一型へ写像するため、将来の分離余地が狭まる。issue の対応表を更新し続け、必要になった時点で型分離を検討する。
- ロールバック: builder 層の追加と内部 snapshot に限定。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] `with_name` / `with_tag` / `with_labels` / `with_ready_conditions` を追加し、override の last-wins と start 時 snapshot の契約を固定する

## 注記

- 参照: [image.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/image.mbt)、[runtime.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/runtime.mbt)、[src/core/containers/request.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/containers/request.rs)、[src/core/image/image_ext.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/image/image_ext.rs)。
- 関連: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の "ContainerRequest / labels / mounts" 行。0010（create / start）と 0049（エラー分類）、0051（consumer API）が本契約に依存する。
- 証跡として override 対応表と wbtest の対象一覧を issue または docs に残す（0050 / 0053 の比較と revision 記録に接続）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた


## 実装メモ（upstream 対応表）

| upstream (request.rs / image_ext.rs) | 意味論 | MoonBit `GenericImage` | 判定 |
|---|---|---|---|
| `image_name` / `image_tag` override | descriptor は override 優先 | `with_name` / `with_tag`（非空必須）→ `descriptor()` | 一致 |
| `overridden_cmd`（空なら image CMD） | 置換、空でフォールバック | `with_cmd` は置換（`command.copy()`）。空配列 → Cmd フィールド無しでイメージ既定 CMD — upstream と同等の結果 | 一致 |
| env マージ（request 勝ち） | キー単位 last-wins | `with_env_var` が既存キー除去+末尾追加 | 一致（順序は契約外） |
| `with_label` / `with_labels` | キー単位 insert / extend | 同名 `with_label`、bulk 版 `with_labels` 追加 | 一致 |
| `with_ready_conditions` | リスト置換・後勝ち | `with_ready_conditions` 追加（入力を copy） | 一致 |
| `with_wait_for` 相当 | upstream は conditions 置換のみ | `with_wait_for` は蓄積のまま維持（既存互換） | 意図的差異 |

snapshot 境界: `build_run_args` は argv を即時 materialize するため CLI 経路は既に非影響。direct 経路は `start_with_client` が `self` に合成 name/label を注入していたため `snapshot()` で分離 — 呼び出し側 builder は不変になった（wbtest で固定）。Container は image を保持しない。
