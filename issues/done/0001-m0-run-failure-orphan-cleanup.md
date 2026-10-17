# [P0 / M0] CLI run が ID を返す前に失敗した場合の orphan 回収

Status: done
Model: SWE-2 Max
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M0
Depends on: なし
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

`GenericImage::start` の CLI run が container ID を受け取る前に失敗・タイムアウトしても、その起動要求が作成したコンテナだけを回収する。ユーザーが既に持つコンテナは削除しない。

## 背景

- 現行 M0 は `runtime.mbt` の `start` が `docker run --detach`（または Apple `container run --detach`）の stdout から ID を読み、readiness 失敗時は `errdefer` で `rm` する。
- run 自体が非ゼロ終了すると stdout に ID が出ず、作成済みコンテナが残る可能性がある。`docs/APPLE_E2E.md` の Boundaries は "Starting a container that fails during CLI `run` before its ID can be read may leave an orphan." としてこれを明記し、マージゲートにも含めている。
- upstream は Engine API / XPC で create と start を分離し、失敗時は create で得た ID を使って rollback する。この問題は ID を一括で受け取る CLI adapter 固有で、M0 の受入経路（0002 / 0003）に影響する。

## 問題

- `start` の `@shell.Cmd(...).output(timeout_ms=...)` がタイムアウトまたは非ゼロ終了で戻ると、`container` 値が構築されず `errdefer` が設置されないため、回収処理が動かない。
- ユーザーが `with_container_name` を指定していない場合、残存コンテナを特定する手段がなく、次回起動が `--name` 衝突などで失敗し得る。
- 逆に name を指定して run が失敗した場合、同名の既存コンテナを force remove してしまう危険がある。

## 目標

- run 失敗直後に、当該起動要求が作成したコンテナが 1 つも残らない。
- 回収対象は所有を証明できる識別子（起動前に確定した name と label）に限定する。
- ユーザー所有コンテナ、他プロセス所有コンテナ、以前の run の残骸を誤削除しない。
- 回収処理の失敗で元の run エラーを上書きしない。

## 対象外

- readiness 待ちの途中失敗に対する rollback（既存 `errdefer` の維持。回帰は 0005 で固定する）。
- プロセスの SIGKILL 後に残ったコンテナの検出・回収（0021 / 0042）。
- Docker Engine API 直結経路の rollback（0006–0011）と Apple XPC（M2）。本 issue は CLI adapter の修正に限定する。
- グローバルなゴミ回収（他の起動要求やユーザー作成コンテナを探して消すこと）。

## 提案する方針

- `runtime.mbt` の `start` で run 前に起動要求 ID（run ID）を発行する。乱数・時刻・連番を組み合わせ、毎回異なり推測困難な値にする。
- `container_name` 未指定時は `container-mbt-<run-id>` のような name を生成し、常に `--name` と label（例: `container-mbt.owned=<run-id>`）を渡す。`commands.mbt` の `build_run_args` を拡張して label 引数を組み立てる。
- `@shell.Cmd` のタイムアウト・非ゼロ終了の経路で、生成 name に対し所有確認と削除の best-effort 回収を行う。
  - 所有確認: `docker inspect`（Apple は `container inspect`）で label の run ID が一致する場合だけ削除する。label が読めない、または不一致なら削除しない。
  - 削除: 既存の `build_remove_args` を再利用し、起動 deadline とは独立した短い有界予算（例: 5 秒）で実行する。
- ユーザー指定 name の場合: run 前に同名コンテナの有無を調べ、存在すれば副作用の前にエラーにする（誤回収と名前衝突の両方を防ぐ）。
- run クライアントを kill した場合、daemon 側で create が後から完了する競合がある。回収確認を上限付きで複数回行い、コンテナ出現を短時間待てる形にする。
- 回収の失敗理由は握りつぶさず、元エラーの文面へ回収結果を付記できるようにする。

## 受け入れ条件

- [ ] Given entrypoint 不正などで run が非ゼロ終了し ID を取得できない, when `start` がエラーを返す, then 生成された name のコンテナは `docker ps -a` に存在しない。（未実行: 実 Docker daemon が必要。`smoke/main.mbt` に故障注入ケースを追加済み、CI の docker ジョブで検証）
- [ ] Given run が startup timeout を超過する, when `start` がタイムアウトで失敗する, then 後から作成されたコンテナも含めて残存しない。（未実行: 同上。タイムアウト経路は `errdefer` + `collect_run_attempt` で実装済み、実 daemon での確認は CI）
- [x] Given ユーザーが同名の既存コンテナを所有している, when `with_container_name` で同じ name を指定して `start` する, then run 前に失敗し既存コンテナは変更されない。（`name_in_use_via` の事前 inspect で実装。wbtest「name preflight classifies inspect results」PASS、実 daemon での holder 生存確認は smoke に追加済み / 未実行）
- [x] Given 他プロセス所有の無関係なコンテナが存在する, when 回収処理が実行される, then run ID label が一致するコンテナだけが削除される。（fixture 実行ファイルによる wbtest で label 不一致は rm 不発火・一致のみ rm 到達を確認 PASS）
- [x] 回収処理が失敗しても、run の元エラー（exit code・stderr）がそのまま呼び出し側へ返る。（`collect_run_attempt` は raise しない設計。非ゼロ終了経路は元の exit/stderr に rollback 注記を付記、timeout・取消経路は `errdefer` で回収後に元エラーを再送出）

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: run ID / name の生成が推測困難で一意であること、label 引数の組み立て、ユーザー指定 name の事前衝突検出を検証する。
- Linux Docker 実機（CI の Docker ジョブ）で故障注入する。
  - `--entrypoint` に存在しないパスを指定した run を作り、失敗後に同 name の残存がゼロであることと、無関係な事前作成コンテナが生き残ることを `docker ps -a` で確認する。
  - run タイムアウト経路は期限内に応答しない fixture（巨大 image 指定など）で確認する。実 Docker daemon が必要。
- Apple Silicon 実機: `smoke_apple` に失敗ケースを追加して確認する。物理 Mac は CI に存在しないため、実行できない間は「未実行」と記録し、0002 の実機受入時に併せて実施する。
- テストは生成 name prefix に限定して後始末し、ユーザー所有コンテナを削除しない（`issues/README.md` の運用ルール 5）。

## リスク

- run 失敗時の追加 inspect / rm により失敗パスのレイテンシが増える。起動 deadline とは独立した短い予算に固定して抑える。
- timeout 後の late create 競合: 回収確認に上限を設けた上で、取り逃し得るケースはログで識別できるようにする。
- ユーザー指定 name を自動削除する危険: label による所有証明が得られない場合は削除しない方針を明確にする。
- `--name` の自動生成でユーザーがログ上でコンテナを特定しにくくなる。name と run ID をエラーメッセージに含めて補う。
- ロールバック: 変更は CLI 引数と失敗パスに限定され、成功パスの公開 API 契約を変えない。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [FIX] CLI run が ID を返す前に失敗した場合に残る孤児コンテナを回収する

## 注記

- CLI adapter 固有の問題のため、対応する upstream 実装はない。参照方針は Engine API / XPC の create→start 分離と rollback（`src/core/client/docker_client.rs`、`src/core/client/xpc_client.rs`）とする。
- 関連: [docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の Merge gate、[docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md)。
- 証跡として `docker ps -a` の前後と run の stderr をログまたは artifact に残す（0052 の CI 方針と整合）。
- 0005 が本 issue の回帰テストを固定し、0002 の実機受入は本 issue の完了を前提とする。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-10-17: 実装着手: run ID 採番・label 付き name 生成・所有確認つき回収を runtime/commands に追加する
- 2026-10-17: 実装完了: `run_attempt.mbt`（`RunAttempt`・`next_run_id`・`OWNERSHIP_LABEL`）、`commands.mbt`（`build_run_args(attempt~)` が常時 `--name` と `--label container-mbt.owned=<run-id>` を付与、`build_inspect_args`）、`runtime.mbt`（ユーザー name の事前衝突検出 `name_in_use_via`、所有確認つき回収 `collect_run_attempt`/`collect_owned_container` を起動 deadline 独立の 5 秒予算 + `protect_from_cancel` で実行）。検証: `moon check --target native --deny-warn` PASS、`moon test --target native` 27 件 PASS（新規 8 件: run ID 一意性/形式、生成 name の妥当性、不正 name 拒否、label 付与、precheck 分類、所有 label 不一致は削除しない、不在は no-op、label 一致のみ rm 到達）。実 daemon 必須の AC 2 件は未実行として記録。`smoke/main.mbt` に故障注入（不正 entrypoint）と name 衝突事前拒否を追加済み（CI docker ジョブで実行）。Apple 実機分は 0002 で実施。
- 2026-10-17: 実装・wbtest PASS。実 daemon 必須の AC 2 件は未実行（smoke に故障注入追加済み、CI で検証）
