# [P2 / M1] Podman 等 Engine API 互換環境の互換境界を記録

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P2
Milestone: M1
Depends on: [0020](./0020-m1-linux-native-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Podman rootless と Docker rootless を含む Docker Engine API 互換ランタイムで、どの操作が動くかを実測し、socket・API 差・rootless 権限制約を capability matrix に PASS / FAIL / 未実行として記録する。

## 背景

- upstream の `README.md` 要件表は Linux を "Docker Engine (Docker Engine API 互換)" とし、"Podman 等 API 互換ランタイムも可" と記載する。一方で upstream のテストは `/var/run/docker.sock` を前提にした Docker Engine に限定されており、Podman compat socket は検証していない（upstream の issues/closed でも同じ限定を明記している）。
- upstream の [src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs) は socket path を `/var/run/docker.sock` 固定の既定値として持つ。
- 本リポジトリの README は "Linux with docker CLI and a running Docker-compatible engine"、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) は "Docker Engine HTTP over Unix socket" とのみ記載する。
- 0006 が socket path とリクエストを構造化し、0011 が lifecycle、0017 が HTTP status 分類を提供する。
- rootless では socket の場所と権限が通常と異なり、network / user namespace の制約が port publish や exec の権限にも影響する。

## 問題

- 互換ランタイムの挙動差を記録する場所がなく、未確認を「対応済み」と誤認する余地がある。
- socket path が既定と異なる環境では接続自体に失敗し、不存在と権限拒否の区別ができないと原因が分かりにくい。
- rootless 特有の制約（低ポートの publish、bridge IP、exec の uid など）が未記録である。

## 目標

- Docker Engine（rootful）の基準動作を維持する（0020 の受入が正）。
- Podman rootless / Docker rootless の各操作について PASS / FAIL / 未実行を実測で記録する。
- socket path と権限の差、非対応 operation を診断可能にする。
- rootless 特有の制約を記録し、沈黙の失敗を残さない。

## 対象外

- 互換ランタイムでの PASS を M1 の必要条件にすること（0020 の Docker Engine 受入が基準）。本 issue は境界の記録と診断。
- Windows / macOS の Docker Desktop（macOS は M2 の 0032）。
- Podman 固有機能（pod、quadlet 等）の対応。
- 複数 socket の自動探索による暗黙フォールバック（0019 の「明示指定のみ」方針に従う）。
- registry 認証の差（Linux 側は 0016）。

## 提案する方針

- 記録先を新規 `docs/ENGINE_COMPATIBILITY.md`（新規、実装詳細として変更可）とし、次の matrix を置く。
  - 列: Docker Engine rootful（基準）/ Docker rootless / Podman rootless。
  - 行: socket 接続 / `_ping` 相当の到達 / API version 検出 / pull / create + start / wait / exec / logs / inspect（ports / bridge IP）/ stop / rm / 動的 host port。
  - 各セルは PASS（実測日・ランタイム version・証跡への参照）/ FAIL（エラー本文）/ 未実行（理由）のいずれかとし、空欄を許さない。
- socket 設定: 0006 の socket path 構造を前提にし、明示設定で差し替えられることを確認する。不足する場合は本 issue で最小の設定追加を行い、既定は `/var/run/docker.sock` のまま維持する。候補 path（`$XDG_RUNTIME_DIR` 配下のユーザー socket 等）は実測した値を記録し、記憶で断定しない。
- 診断: 接続失敗を (a) socket 不存在、(b) 権限拒否、(c) 非 HTTP 応答、に区別する。分類は 0006 / 0017 のエラー体系に従う。
- CI: 必須ゲートにはしない。Podman が利用可能な Linux runner（または手動の Linux ホスト）で optional に実行し、結果を matrix へ転記する。CI で実行できない間は「未実行」と記録し、PASS として扱わない。
- rootless の制約記録: 低ポート（1024 未満）の publish 可否、network モード、bridge IP 取得、exec の実行 uid、bind mount の権限。実測できたものだけを PASS / FAIL として書き、確認できていないものは未実行とする。
- README / `docs/PORTING.md` の互換表現は matrix を参照する形に整え、「対応済み」と断定しない。

## 受け入れ条件

- [ ] Given Docker Engine rootful, when 0020 の E2E を実行する, then 従来どおり PASS し回帰がない。**未実行**（CI `smoke_linux` step が基準測定 — 初回 CI 実行で採証）
- [ ] Given Docker rootless または Podman rootless（実行可能な環境）, when matrix の行の操作を実行する, then 各セルが PASS / FAIL / 未実行で埋まり、根拠（version・手順・エラー本文）が記録されている。**未実行**（matrix 作成済み・全セル記入、両環境とも未実測と明記。実測手順を docs/ENGINE_COMPATIBILITY.md に記録）
- [x] Given socket path が既定と異なる環境, when 明示設定する, then 接続でき、設定がない場合は「socket 不存在」を区別したエラーになる。(`DockerClient::new(socket_path~)` で差替済み — mock socket 全テストが非既定 path で実接続。不存在は `SocketMissing` → `TransportError("…does not exist")` で区別 — wbtest 検証)
- [x] Given 権限不足の socket, when 接続する, then 権限拒否と分かるエラーになる（不存在と混同しない）。(`PermissionDenied` → `TransportError("permission denied opening …")` — wbtest が 000 権限 dir で実検証；client 経由の detail 保存も検証)
- [x] Given 非対応 operation, when 実行を試みる, then 事前検証または明確なエラーとして失敗し、沈黙の成功にならない。(0019 の capability matrix が dispatch 前に Rejected/NYI で明示失敗；engine error 分類が 404/409/500 等を型付きで返す)
- [x] Given matrix のドキュメント, when 未実行セルを確認する, then PASS と区別して記載され、理由が付いている。(docs/ENGINE_COMPATIBILITY.md: 全セルに PASS/FAIL/未実行＋理由、空欄なし)
- [ ] rootless 固有の制約（publish / exec / mount の少なくとも 1 項目）が実測結果として記録されているか、未実行の理由が明記されている。**未実行の理由を明記**（5 項目すべてに未実行理由；実測手順を文書化 — 環境不在のため）

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: socket path の解決、接続エラー分類（不存在 / 権限 / 応答不正）、明示設定必須の挙動。
- Linux Docker rootful: 0020 の E2E を実行（基準）。PASS を記録。
- Docker rootless / Podman rootless: 実行可能な Linux 環境で optional に実行し、結果と version を matrix に転記する。CI へ常設できない場合は「未実行」と明記する。
- Apple Silicon 実機: 対象外。

## リスク

- rootless 検証が環境依存で再現しない。実行環境の version・手順・生のログを記録し、CI の必須条件にしない。
- 互換対応を「対応済み」と誤解させる。matrix のセル単位で明示し、README の表現も matrix 参照に留める。
- socket 設定の追加で既定動作が変わる。既定は `/var/run/docker.sock` を維持し、明示設定時のみ差し替える。
- 互換ランタイムの応答差で既存パーサが誤動作する。差を記録し、必要なら 0017 の分類へフィードバックする。
- ロールバック: matrix が中心で、コード変更は socket 設定と診断メッセージに限定する。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: upstream `README.md` の要件表と "Podman 等 API 互換ランタイムも可" の記載、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（既定 socket と接続の構造）、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡: 各セルの実測ログ、ランタイムの version、socket path と権限の実測値。
- 公開 API の追加（明示 socket 設定が 0006 で不足する場合）が生じた場合、`CHANGES.md` の impact 判断は実装時に再評価する。
- 関連: 0006・0017・0020・0019。互換記録は 0032 / 0050 の比較にも使う。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`docs/ENGINE_COMPATIBILITY.md` 新設 — 3 列（Docker rootful/Docker rootless/Podman rootless）×14 行 matrix、全セル PASS/FAIL/未実行＋理由で記入。socket 設定は既存の `DockerClient::new(socket_path~)` で充足（追加 API 不要、既定 `/var/run/docker.sock` 維持、暗黙探索なし）。接続失敗の 3 分類（不存在/権限/非 HTTP）は既存 error 体系で成立 — client 経由の detail 保持を新 wbtest で検証。rootless 制約表（低 port publish/ネットワーク/bridge IP/exec uid/mount 権限）と候補 socket path（unverified 明記）、実測手順を文書化。README/PORTING は matrix 参照表現に更新し「対応済み」表現を排除。moon check --deny-warn PASS、157 tests PASS。実測は環境不在で全て未実行 — CI/手動 Linux で採証する手順は文書化済み。
