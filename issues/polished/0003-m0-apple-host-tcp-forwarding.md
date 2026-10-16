# [P1 / M0] Apple CLI 固定 published port の TCP 到達を検証

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M0
Depends on: [0002](./0002-m0-apple-cli-physical-e2e.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Apple Container CLI の固定 published port（`--publish 18080:80/tcp`）について、ホストから実際に TCP 接続して応答本文を受け取れることを物理 Mac で検証する。ポート番号の取得確認だけでは完了にしない。

## 背景

- [smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt) は `get_host_port_ipv4` が 18080 を返すことだけを確認しており、ホストからの TCP 接続は検証しない。
- [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の Boundaries が "It checks the returned fixed port number, **not end-to-end host TCP connectivity**; verify network forwarding separately before claiming host-port conformance." と明記している。
- upstream は Linux で inspect から bridge IP と publish 情報を解決する（0014 / 0015）。Apple Container 側の port 検査は XPC の 0030 が担当し、本 issue は M0 CLI adapter の実機検証に限定する。
- 0002 の実機受入と同じセッションで実施する位置づけ。

## 問題

- `--publish` の番号が返っても、ホストで listen しコンテナまで TCP が通るかは証明できていない。
- 18080 が使用中のときの扱いが未定義で、黙ってスキップすると受入が空振りする。
- macOS のローカルネットワーク権限や firewall で接続が拒否された場合に、転送不良と環境要因を区別する手段がない。

## 目標

- 固定ポート 18080 で TCP / HTTP 応答 fixture を起動し、ホストから接続して内容と切断挙動を検査する。
- ポート占有時はスキップせず、明示的な環境エラーで失敗する。
- 権限・firewall による接続拒否を転送不良と混同しない。
- 検証後にテストコンテナだけが消える。
- 接続先・HTTP status・body・実行ログを TCP 往復の証跡として残す。

## 対象外

- Apple Container XPC の port mapping 実装（0030、M2）。
- 動的 host port の解決（0014、Apple 側は 0030）。
- M0 smoke 全体の完走（0002）。本 issue はその中の TCP 到達検証だけを担う。
- capability 表の整備（0004）と Linux 側の回帰テスト（0005）。

## 提案する方針

- [smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt) に TCP 到達検証を追加する。別ファイルへの切り出しは実装詳細として変更可。
- fixture は Alpine 上で利用できる静的応答サーバを使う。候補（例: BusyBox の HTTP サーバ機能）は実機で動くことを確認してから採用し、未確認のコマンドを断定しない。
- ホスト側の接続手段は `moonbitlang/async@0.22.4` に TCP クライアント API があるかを調査して決める。外部コマンド（`curl` など）を使う場合は `@shell.Cmd` の argv 配列で実行し、出力をログに残す。
- run 前に `lsof -nP -iTCP:18080 -sTCP:LISTEN` で空きを確認し、listener があればコンテナ作成前に `fail(...)` で明示エラーにする（スキップ禁止）。
- 接続拒否 / timeout のエラーには、ローカルネットワーク権限や firewall の可能性を診断として含める。拒否時の具体的なエラー識別は実機で観測してから固定する。
- 検証後は既存 `smoke_apple` と同じく errdefer と明示 `rm` で削除し、`container inspect` または `container list --all` で残存ゼロを確認する。ユーザー所有コンテナには触れない。

## 受け入れ条件

- [ ] Given 物理 Mac で 18080 が空いている, when smoke を実行する, then ホストから `127.0.0.1:18080` への TCP 接続が成功し、fixture の HTTP status と body が期待値に一致する。
- [ ] Given 18080 に既存の listener がある, when smoke を実行する, then コンテナ作成前に明示的な環境エラーで失敗する（スキップしない）。
- [ ] Given ローカルネットワーク権限や firewall で接続が拒否される, when smoke を実行する, then 転送不良と混同せず、環境要因の可能性が分かるエラーと証跡になる。
- [ ] Given 検証終了後, when `container list --all` を確認する, then テストコンテナが残存せず、無関係な既存コンテナも変化しない。
- [ ] Given 検証結果, then 接続先 / HTTP status / body / 実行ログが証跡として保存される。
- [ ] Given 変更が MoonBit コードを含む, when `moon check --target native --deny-warn` と `moon test --target native` を実行する, then PASS する。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
- 物理 Mac で 0002 の smoke 完走と同一セッションで実行し、TCP 往復の証跡（`curl -v` 相当の出力を含む）を保存する。
- fixture と接続手順が実機で動くことを確認する。手動での `curl` 確認を併用してよい。
- 物理 Mac が使えない間は「未実行」と明記し、Linux CI や擬似テストで代替しない（[issues/README.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/issues/README.md) ルール 4）。
- 終了後の `container list --all` でテストコンテナ残存ゼロを確認する。

## リスク

- 18080 固定で他プロセスと衝突しやすい → 実行前チェックと明示エラー（スキップ禁止）。動的ポートが必要になったら 0030 の XPC 検証で扱う。
- ローカルネットワーク権限の初回ダイアログで実行が止まる → 事前許可を手順に含め、失敗時は権限要因として記録する。
- fixture が実機の Alpine で起動しない → 実機で確認した手順だけを採用し、実行コマンドを証跡に残す。
- cleanup 漏れ → 固有 name、errdefer、`container inspect` の 3 段で確認する。

## 変更履歴

`CHANGES.md` impact: no

判断理由: 実機検証と smoke の証跡強化が中心で、利用者に見える API・挙動を変えない。

## 注記

- docs/APPLE_E2E.md の Boundaries: TCP 到達は別途検証が必要。本 issue の結果を 0002 の証跡へ加える。
- 関連: [smoke_apple/main.mbt](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/smoke_apple/main.mbt)、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)、upstream [src/core/ports.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/ports.rs)。
- 0002 完了が前提。0005 の回帰テストは Linux 側を担う。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
