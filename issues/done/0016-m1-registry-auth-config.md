# [P1 / M1] Docker registry 認証と秘密情報保護

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M1
Depends on: [0009](./0009-m1-native-image-pull.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

Docker の静的認証設定（`DOCKER_AUTH_CONFIG` / `DOCKER_CONFIG/config.json` / `~/.docker/config.json`）を読み、registry ごとの `X-Registry-Auth` ヘッダ値を組み立てる。優先順・Docker Hub key 正規化・identitytoken/auth の扱いを upstream と揃え、認証情報をログやエラーへ漏らさない。credential helper は非対応と明記する。

## 背景

- M1 の image pull（0009）は公開 image の匿名 pull までは実装されるが、private registry の認証設定を読む経路がない。`docs/PORTING.md` も registry auth を未実装の機能として挙げている。
- M1 は Linux で Docker Engine API に Unix socket で直結する（CLI 非依存）。0006 が transport、0007 が HTTP 応答解析の基盤で、0009 の pull/resolve リクエストに認証ヘッダを付与する本 issue はその上に載る。
- upstream の `src/core/client/registry_auth.rs` は `DOCKER_AUTH_CONFIG` > `DOCKER_CONFIG/config.json` > `~/.docker/config.json` の優先順で config.json を読み、`auths` の静的エントリだけを使う。`identitytoken` が非空なら `{"identitytoken":"..."}`、なければ base64 `auth`（`user:pass`）をデコードして `{"username","password","serveraddress"}` を組み立て、外側を base64 した値を返す。credential helper（`credsStore` / `credHelpers`）は参照しない。
- upstream の key 正規化: `/` を含まない参照（`alpine:latest` 等）は Docker Hub の `https://index.docker.io/v1/`。先頭コンポーネントが `docker.io` / `index.docker.io` の場合も同キーへ正規化する（この 2 ドメインのみ）。`registry-1.docker.io` やポート付きホストは正規化しない。`DOCKER_CONFIG` が非空なら、そのディレクトリだけを見て `~/.docker` へフォールバックしない（docker CLI 準拠）。

## 問題

- private registry の pull が常に匿名になり、認証が必要な image を取得できない。
- Docker Hub の参照形（`alpine`、`docker.io/org/img`、`index.docker.io/...`）と config.json の key の対応規則がないため、正しく実装しても key 不一致で認証が拾えない危険がある。
- `identitytoken`（Docker Hub のトークン）と `auth`（base64 user:pass）の優先関係が未定義。
- 認証情報をどこにも漏らさない要件（ログ、エラーメッセージ、panic 出力、fixture）が未整備。

## 目標

- 3 つの設定ソースを upstream と同じ優先順で読み、指定 image に対する `X-Registry-Auth` ヘッダ値を返す。
- Docker Hub key の正規化規則を upstream と揃え、`docker.io` / `index.docker.io` の特殊形と `registry-1.docker.io` 非正規化を fixture で固定する。
- `identitytoken` 優先、`auth` の base64 デコード、非空チェックの順でヘッダを組み立てる。解決できない場合は匿名（ヘッダなし）として扱い、pull 自体は続行する。
- credential helper 非対応をコードの doc コメントとドキュメントに明記する。
- 認証情報をログ・エラー・テスト証跡へ出さない。

## 対象外

- pull 本体（`/images/create`、進捗 stream、404/認証エラーの分類）は 0009。本 issue はヘッダ値の生成と設定読み込みを提供する。
- transport と HTTP 解析は 0006/0007。HTTP 失敗分類の実装は 0017。
- credential helper 連携（`docker-credential-*` の起動）は実装しない。対応が必要になった場合は別 issue とする。
- Apple Container XPC の pull 認証は M2 の 0025。Podman 互換は 0022。秘密情報の系統的な非漏出検証は 0054。

## 提案する方針

- 新規ファイル（例: `registry_auth.mbt`、実装詳細として変更可）に認証設定のローダーとヘッダビルダーを置く。
  - ローダーは「環境変数の値（`DOCKER_AUTH_CONFIG`、`DOCKER_CONFIG`、`HOME`）とファイル内容の読み取り関数」を引数に取る純関数的な形へ分ける。プロセス環境を直接書き換えずに wbtest できるようにする（環境変数の隔離は子プロセス fixture を使う場合も upstream と同じ方式に揃える）。
  - 優先順: `DOCKER_AUTH_CONFIG` が非空ならそれを使う。空文字・未設定なら `DOCKER_CONFIG` が非空のときその配下の `config.json` のみを読む（欠落・読取失敗なら匿名で確定し、`HOME` へフォールバックしない）。`DOCKER_CONFIG` が空・未設定なら `HOME` 配下の `.docker/config.json` を読む。
  - `auths_key(reference)`: 参照が `/` を含み、かつ先頭コンポーネントがホスト形式（`.` / `:` を含む、または `localhost`）の場合は先頭コンポーネントを key にする。それ以外（`/` を含まない、または先頭がホスト形式でない）は Docker Hub key。ただし先頭が `docker.io` / `index.docker.io` の場合は Hub key へ正規化する（この 2 ドメインのみ）。
  - エントリ解決: `auths[key].identitytoken` が非空なら `{"identitytoken":"..."}` を base64。なければ `auths[key].auth` を base64 デコードして `user:pass` に分割し、`{"username":"...","password":"...","serveraddress":"<key>"}` を base64 して返す。key 不一致、`auths` 欠落、base64 不正、`:` なし、空 `auth` はすべて匿名（ヘッダなし）とする。
  - ヘッダは 0009 の pull/resolve リクエストにのみ付与する（`X-Registry-Auth`。upstream の `request_with_extra_headers` 相当）。
- 秘密情報保護: ヘッダ値・config 内容・デコード後の資格情報をログ、エラーメッセージ、デバッグ出力に含めない。エラーは参照名と「認証が見つからない / config.json が読めない」という事実のみを伝える。wbtest でエラー文面に資格情報が現れないことを確認する。
- credential helper: `credHelpers` / `credsStore` のフィールドが存在しても解釈せず、静的 `auths` の対象外であることを doc コメントに明記する。該当フィールドしかない場合は匿名 pull になる。
- `docs/PORTING.md` の該当行（registry auth 未実装）を更新する。

## 受け入れ条件

- [x] Given `DOCKER_AUTH_CONFIG` と `DOCKER_CONFIG/config.json` と `~/.docker/config.json` が同時に存在する, when 認証を解決する, then `DOCKER_AUTH_CONFIG` の内容が優先される。(`select_auth_source` + async loader の env 固定テスト)
- [x] Given `DOCKER_AUTH_CONFIG` が空文字, when `DOCKER_CONFIG` が非空のディレクトリを指す, then その配下の `config.json` のみを読み、欠落時は `~/.docker/config.json` へフォールバックせず匿名になる。(tmpdir fixture: DOCKER_CONFIG の空 dir + 有効な HOME config → None)
- [x] Given `DOCKER_CONFIG` が空・未設定, when `~/.docker/config.json` が存在する, then それが使われる。(同上 fixture)
- [x] Given `alpine:latest` / `library/nginx` / `docker.io/org/private` / `index.docker.io/org/private` を解決する, when key を求める, then すべて `https://index.docker.io/v1/` になる。
- [x] Given `ghcr.io/org/app` / `localhost:5000/img` / `registry.example.com/img` を解決する, when key を求める, then ホスト名そのものが key になる。
- [x] Given `registry-1.docker.io/org/img` または `docker.io:5000/img` を解決する, when key を求める, then 正規化されず先頭コンポーネントが使われる。
- [x] Given エントリに `identitytoken` と `auth` が両方ある, when ヘッダを組み立てる, then `identitytoken` が優先される。
- [x] Given `auth` が base64 の `user:pass`, when ヘッダを組み立てる, then `username` / `password` / `serveraddress` を持つ JSON が base64 されて返る。(`Json::stringify` で制御文字・引用符を正しくエスケープ — fixture 固定)
- [x] Given `auths` 欠落・key 不一致・base64 不正・空 `auth`, when 解決する, then ヘッダなし（匿名）になり、エラーで pull を妨げない。
- [x] Given 認証を解決した結果, when ログ・エラー・テスト出力を確認する, then 資格情報（token、base64、平文 user:pass）が現れない。(解決失敗は `None` を返すだけでエラーを構築しない;mock daemon の 401 エラー文面に token/その base64 が含まれないことを検証)
- [x] Given credential helper のみが設定された config.json, when 解決する, then helper は呼ばれず匿名になり、非対応であることがドキュメントに明記されている。(`registry_auth.mbt` doc + PORTING.md 行)
- [x] Given 公開 image の匿名 pull, when 認証設定が一切ない, then 0009 の pull が従来どおり成功する。(148 tests PASS — 認証なしでも従来のヘッダ構成)

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: 優先順（env と読み取り関数の注入）、key 正規化の全ケース、`identitytoken` 優先、base64 `auth` のデコード、制御文字を含む資格情報、空 `auths`、key 不一致、エラー文面の非漏出。
  - 環境変数の優先順を実環境で確認する場合は、upstream と同じく子プロセス fixture（`moon run` の小さな検証エントリ等）で隔離し、テストプロセス全体の環境を書き換えない。
- Linux Docker 実機（CI の Docker ジョブ）: 0009 の公開 image pull E2E が引き続き成功することを確認する。
- private registry の実認証 E2E は CI に資格情報がなく、検証用レジストリの常設も本 issue の範囲外のため「未実行」と記録する。実施する場合はローカル registry fixture を別途用意し、その旨を証跡に残す。
- Apple Silicon 実機: 本 issue は Linux 直結経路のため対象外（XPC pull 認証は 0025）。
- Podman 等の互換 Engine は 0022 のため未実行。

## リスク

- key 正規化の不一致で Docker Hub の認証が拾えない。upstream の `auths_key` と同じ規則を fixture で固定する。
- 秘密情報の漏出。ヘッダ値を戻り値以外に保持・出力しない方針をテストで守り、エラー文面を fixture 化する。
- `DOCKER_CONFIG` のフォールバック規則の解釈違い（docker CLI はフォールバックしない）。優先順テストで固定する。
- credential helper 非対応の暗黙の失敗。匿名で続行する理由と対処（`DOCKER_AUTH_CONFIG` の利用）をドキュメントに明記する。
- ロールバック: 新規ファイルに閉じ、0009 の pull 経路への追加はヘッダ付与のみ。問題時は該当コミットの revert で戻せる。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] Docker registry の静的認証設定（DOCKER_AUTH_CONFIG 等）の読み込みと X-Registry-Auth 生成を実装する

## 注記

- upstream 参照: [src/core/client/registry_auth.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/registry_auth.rs)（`auths_key`、`x_registry_auth`、`load_config_json`、`extract_auth_entry`、`DOCKER_HUB_AUTH_KEY`）、[src/core/client/docker_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/docker_client.rs)（`request_with_extra_headers`）。
- 関連ロードマップ: [docs/PORTING.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/PORTING.md) の「Registry auth」を本 issue で解消する。
- 証跡: fixture config.json（資格情報はダミー値）、key 解決結果、ヘッダの構造（値はマスク）、非漏出テスト結果を残す。実在の資格情報をリポジトリやログへ残さない。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
- 2026-11-04: 実装。`registry_auth.mbt` 新設: `select_auth_source`（優先順の純粋関数、DOCKER_CONFIG 非空時は HOME フォールバックなし）、`auths_key`（docker.io/index.docker.io のみ Hub key 正規化、registry-1.docker.io / ポート付きは正規化しない）、`extract_auth_entry`（identitytoken 優先、auth base64→UTF-8 厳格デコード→先頭 `:` で分割、全失敗は None）。ペイロード構築は `Json::stringify` でエスケープ安全。`resolve_image`/`pull_image` に `X-Registry-Auth` を付与（`registry_auth_headers`、解決失敗は匿名で続行）。`fs`/`base64`/`encoding` 依存を moon.pkg に追加（fs は wbtest-only から昇格）。PORTING.md の matrix 更新（registry auth 行追加、M1 実装済み行の陳腐化解消）。mock daemon でヘッダ送出と 401 エラー非漏出を検証。moon check --deny-warn PASS、148 tests PASS。private registry の実認証 E2E は未実行（CI、検証用 registry 常設外）。
