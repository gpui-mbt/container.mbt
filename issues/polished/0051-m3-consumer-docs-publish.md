# [P2 / M3] Mooncakes consumer から使える公開 API・文書・配布

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M3
Depends on: [0048](./0048-m3-image-request-api-parity.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

mooncakes の独立 consumer が依存解決から start / rm まで通ることを確認し、README に Docker / Apple の例とサポート表を追加して、公開条件（バージョン / 承認）を満たした後に publish できる状態にする。

## 背景

- [moon.mod](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/moon.mod) は name / version / readme / repository / license / keywords / description / `preferred_target = "native"` と `moonbitlang/async@0.22.4` を持つ。CI は `moon package --list` を実行している（[.github/workflows/ci.yml](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/.github/workflows/ci.yml) 31–32 行付近）。
- [README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md) は "Status: initial, incomplete port" と API の要点・Requirements・制限を持つが、コピー可能な使用例（Docker / Apple）とサポート表はない。
- [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) は機能別の対応状況を持つが、利用者向けのサポート宣言（OS / runtime / version / 制限）ではない。
- 依存の 0048 で公開 API の override 契約が固まる前提。公開 API が動くのは consumer の実ビルド・実行で確認する必要がある。

## 問題

- リポジトリ内の unit / smoke だけでは、外部 MoonBit プロジェクトから依存として使える保証がない（パッケージ境界、公開シンボル、required import の過不足）。
- README にコピー可能な最小例がなく、Docker と Apple で何が動く／動かないかを利用者が判断できない。
- supported OS / version と非互換点（明示 `rm` 必須、Drop cleanup なし、target は native）が利用者向けに宣言されていない。
- 公開手順（誰の承認で、どのバージョンを、どの条件で公開するか）が未定義。

## 目標

- 独立 consumer sample（このリポジトリの外の最小プロジェクト）が依存解決・build し、Docker 実機で start / exec / logs / rm まで動く。
- README に Docker / Apple の最小例と、サポート表（OS / runtime / version / 制限 / 検証状況）がある。
- moon.mod のメタデータが mooncakes の公開条件を満たす。
- 公開はバージョン確定と承認後に行い、本 issue の完了時点では公開しない。

## 対象外

- 実際の mooncakes publish の実行とバージョン番号の決定（承認後に別作業として行う）。
- API 設計の変更（0048）。
- CI ワークフローの整備（0052）。consumer ビルドを CI に載せるかは 0052 と協議する。
- パッケージ名の変更（`gpui-mbt/container` を前提にする）。

## 提案する方針

- consumer sample はこのリポジトリに追加せず、別ディレクトリ / 別 project として作成する（手順とパスを issue に記録する）。最小コードは次の形。
  ```moonbit
  let image = @container.GenericImage::new("alpine", "3.20")
    .with_cmd(["tail", "-f", "/dev/null"])
  let container = image.start(@container.Docker)
  let out = container.exec(["sh", "-c", "printf moonbit-consumer"])
  container.rm()
  ```
  import 名（`gpui-mbt/container`）と `moon.pkg` の依存記法は実装時に mooncakes / moon のドキュメントで確認する（捏造しない）。
- README 追記:
  - Docker 例（Linux、`start(@container.Docker)`）と Apple 例（macOS 26 / Apple Silicon、`start(@container.AppleContainer)`）の完全なコード。
  - サポート表: 列 = OS / runtime / version 要件 / 検証状況（PASS / 未実行）/ 制限。Linux + Docker は CI 検証済み、macOS 26 + Apple Silicon + Apple container 1.2.0 以上は実機受入まで「未実行」と明記する。
  - 非互換点: 明示 `rm` 必須（Drop cleanup なし）、native target 限定、公開 API の未実装範囲（docs/PORTING.md へリンク）。
- moon.mod: 公開条件（license / readme / repository / description / keywords など）を mooncakes の要件と照合して不足を補う。version は 0.x のまま据え置き、公開時に決定する。
- 公開フロー（記録として残す）: 承認 → `moon package --list` で内容確認 → 公開。公開コマンドと前提条件は実装時に moon のドキュメントで確認する。
- 証跡: consumer の build / E2E ログ、README のサポート表の各セルに検証状況を付ける。

## 受け入れ条件

- [ ] Given 独立 consumer プロジェクト, when mooncakes 依存を解決して build する, then 成功する。
- [ ] Given 同 consumer, when Docker 実機で start / exec / logs / rm を実行する, then 成功し、テスト用 prefix の残存コンテナがない。
- [ ] Given README, when 読む, then Docker / Apple の完全な例とサポート表（検証済み / 未実行の区別、version 要件、明示 rm 必須）がある。
- [ ] Given moon.mod, when `moon package --list` 相当で確認する, then 公開に必要なメタデータが揃っている。
- [ ] Given バージョン未決定・未承認の状態, when リポジトリを確認する, then 公開操作は行われていない。
- [ ] Given リポジトリ内の既存 API 利用者（smoke など）, when 変更後にビルドする, then 壊れない。

## テスト計画

- `moon check --target native --deny-warn` / `moon test --target native` / `moon build --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 独立 consumer のビルドと Docker 実機 E2E を実行する。CI の docker-e2e ジョブで確認できない場合は手動で実行し、コマンドと結果を記録する。
- Apple consumer は物理 Mac が必要なため「未実行」と理由を記録し、0002 / 0032 の受入後に確認する。GitHub-hosted macOS runner の compile では代替しない。
- README のサポート表はセルごとに検証状況（PASS / 未実行）を明示し、未検証のセルを PASS として書かない。

## リスク

- 公開後に API を変えると互換性負債になる。0.x と未完成状態（未実装範囲）を README / サポート表で明示し、公開を承認後まで遅らせる。
- native 限定を明記しないと他の target で使われて失敗する。`preferred_target` と `supported_targets` を README に書く。
- consumer 側の環境差（Docker なし / Apple 実機なし）で検証が止まる。Linux Docker を必須、Apple を「未実行」として分離記録する。
- README の例が API 変更で腐る。例は wbtest / smoke に存在する呼び出しと揃え、0048 の非破壊方針と連動させる。
- ロールバック: README / moon.mod の変更は独立で戻せる。公開自体を本 issue で行わないため、外部への影響はない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [moon.mod](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/moon.mod)、[README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/README.md)、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 関連: 0048（公開 API 契約）、0052（CI との分担）、0002 / 0032（Apple 実機受入後にサポート表の未実行セルを埋める）。
- mooncakes の公開要件・コマンドは実装時に moon / mooncakes のドキュメントで確認する。CI の `moon package --list` を公開前チェックとして再利用する。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
