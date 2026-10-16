# [P1 / M2] Apple XPC image pull・参照/manifest の確認

Status: polished
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-16
Branch: feat/initial-moonbit-container-port-20261016
Priority: P1
Milestone: M2
Depends on: [0024](./0024-m2-xpc-protocol-contract.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

image pull と参照解決を XPC の image service へ移植し、manifest の platform 選択、image not found、通信不能時の期限付き復帰を実機で検証する。

## 背景

- 現行 MoonBit に pull API はなく、CLI adapter の `docker run` / `container run` が暗黙に pull している。XPC 直結では pull と参照解決を明示的に実装する必要がある。
- upstream の `pull_image` は [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs) にあり、image service（`com.apple.container.core.container-core-images`）へ `imagePull` を送る。引数は `imageReference`、`insecureFlag=false`、`maxConcurrentDownloads=3`、platform 指定時のみ `ociPlatform` の JSON（`{"os":"linux","architecture":"amd64"}` 等。arm64 / amd64 の 2 値で、未指定時はキーごと省略）。待ち時間は長期タイムアウト（24 時間）。
- 参照は `imageReference` の正規化後文字列で行う。upstream の `normalize_image_reference` は、スラッシュなしは `docker.io/library/{image}`、先頭コンポーネントに `.` / `:` を含むか `localhost` ならそのまま、それ以外は `docker.io/{image}` を前置する。
- `resolve_image_descriptor` は `imageList` の `imageDescriptions`（JSON 配列）から `reference` 一致（正規化前後の両方で比較）を探し、`descriptor` を返す。空データ / 一致なしは `ImageNotFound`、非 UTF-8 / 不正 JSON は JSON エラー、一致したが `descriptor` 欠落は別エラーとして扱う。
- upstream の macOS 起動経路（`resolve_or_pull_macos`）は、明示 amd64 指定時は必ず `ociPlatform` 付き pull の後に resolve、それ以外はまず resolve し、`ImageNotFound` のときだけ pull して再 resolve する。許可外の platform 文字列は正規化で未指定扱いになる。
- [src/core/client/image_config.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/image_config.rs) は descriptor の mediaType に応じて index → manifest → config を `contentGet` で辿る。index の manifest 選択は、platform 指定時は os と architecture の一致のみ（一致なしは "no matching manifest for {platform}" でフォールバックしない）、未指定時は arm64 → amd64 → os のみ一致の先頭 → 先頭（attestation 相当の `architecture == "unknown"` を除外）の順である。
- 0024 が request / response 型とエラー整形を提供する。

## 問題

- pull の成功 / 失敗分類が XPC では JSON と error code の組み合わせになり、CLI の stderr 文字列に依存してきた現状では分類できない。
- manifest の platform 選択規則が未移植で、multi-arch image で誤った arch を黙って選ぶ余地がある。
- 通信不能・daemon 停止時の復帰時間が未定義である。

## 目標

- image name / tag と platform を XPC request へ変換して pull できる。
- 取得済み image は resolve でスキップし、未取得のときだけ pull する。
- manifest の platform 選択規則を移植し、明示 platform では一致しない場合にフォールバックしない。
- image not found を型付きエラーとして返す。
- 通信不能・応答なしでは有界時間で復帰し、ハングしない。

## 対象外

- create / start と config 変換（0026）。
- registry 認証（Linux 側は 0016。macOS の認証差は本 issue では扱わない）。
- content store の大容量 blob 最適化（本 issue は config 解決に必要な範囲のみ）。
- 実機受入の完走（0032）。
- CLI adapter の pull 相当（M0）。

## 提案する方針

- 新規 `xpc_image.mbt`（新規、実装詳細として変更可）に `pull` / `resolve_descriptor` / `resolve_or_pull` を実装する（upstream の `resolve_image_descriptor` に相当。名前は実装時に確定）。
- 正規化: upstream と同じ規則を純関数として実装し、wbtest で固定する（`None → docker.io/library/...`、先頭に `.` / `:` / `localhost` があればそのまま、それ以外は `docker.io/...`）。
- platform: `GenericImage` の `with_platform` の許可値だけを `ociPlatform` に載せる（`linux/amd64` / `amd64` → amd64、`linux/arm64` / `arm64` → arm64。それ以外はキー省略）。upstream の `normalize_platform` と同じ対応にする。
- 解決順: 明示 amd64 は pull を必ず行ってから resolve（arm64 のみ取得済みの環境で amd64 digest が取れない経路を潰すため。upstream の根拠コメント付き実装と同じ）。それ以外は resolve → `ImageNotFound` のときだけ pull → 再 resolve。その他のエラーは pull せず伝播する。
- pull の待ち: 送信タイムアウトは長期上限（upstream の 24 時間）を上限とし、テストでは短い値を注入できる形にする。startup deadline（0018 の「タイマーをリセットしない」方針）とは独立に扱い、pull の長さで create / readiness の予算を変えない。接続失敗は即時エラー、無応答は送信タイムアウトで復帰する。
- エラー分類: `imageList` に一致なし / 空 → `ImageNotFound`。`imagePull` が `notFound` を返す場合は `ImageNotFound` へ寄せる（それ以外の XPC エラーはそのまま）。非 UTF-8 / 不正 JSON は 0024 の JSON エラー。
- manifest 選択: `resolve_image_config` 相当を新規 `image_config.mbt`（新規）へ実装する。mediaType が index / manifest list の場合は `contentGet` で index を取得し、platform 選択 → manifest 取得 → config digest → config 取得の順で辿る。manifest（単体）と config 直指定も upstream と同じく分岐する。選択規則は upstream の 4 段（主経路 / arm64 → amd64 フォールバック / os のみ一致の先頭 / 先頭。attestation 除外）をそのまま持ち、platform 明示時は主経路のみで一致なしか "no matching manifest" 相当のエラーにする。
- 純部分（正規化、platform 正規化、manifest 選択、エラー分類）は fixture だけでテストできるようにし、実機依存部分と分離する。
- 検証 fixture: 実機で alpine:3.20 の pull → resolve を実行し、`imageList` / index / manifest の応答を fixture として保存する（0024 の fixture 置き場と共有）。

## 受け入れ条件

- [ ] Given 物理 Apple Silicon の実機, when alpine:3.20 を pull して resolve する, then descriptor が取得でき、直後の create（0026）に渡せる。
- [ ] Given 存在しない tag, when pull / resolve する, then `ImageNotFound` が返り、通信エラーや JSON エラーと区別できる。
- [ ] Given 取得済み image, when start 経路が resolve に成功する, then `imagePull` を送らない（証跡: route ログに pull がない）。
- [ ] Given platform 未指定の multi-arch index, when manifest を選択する, then 規則（主経路 → arm64 → amd64 → os 一致先頭 → 先頭、attestation 除外）どおりに選ばれる。
- [ ] Given platform に linux/amd64 を明示, when manifest に一致がない, then "no matching manifest" 相当の明示エラーになり、別 arch へフォールバックしない。
- [ ] Given daemon 停止または応答なし, when pull する, then 短い timeout を注入したテストで期限内にエラーが返り、プロセスがハングしない。
- [ ] Given 非 UTF-8 または不正 JSON の `imageList` 応答, when resolve する, then 0024 の JSON エラーとして明示され、空扱いや not found に丸めない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - unit（実機不要）: 参照正規化、platform 正規化、manifest 選択の 4 段、`ImageNotFound` の判定、非 UTF-8 / 非 JSON の拒否、fixture デコード。
- 物理 Apple Silicon 実機: public registry から alpine:3.20 の pull、存在しない tag のエラー、daemon 停止時の復帰。GitHub の macOS runner では代替しない。このブランチでは「未実行」と記録する。
- 証跡: Apple container version、route ログ（pull の有無）、エラー本文、fixture のメタデータ。

## リスク

- ネットワーク依存でテストが flaky になる。unit は fixture で固定し、実機確認は registry 到達可能なときに行い、失敗時も「未実行」と「FAIL」を区別して記録する。
- tag の内容が後から変わる。既存 smoke と同じ `alpine:3.20` を使い、digest 固定は将来課題とする（fixture には採取時の descriptor を残す）。
- 24 時間の待ちがテストを長時間化させる。タイムアウトを注入可能にし、テストは短い値で行う。
- `notFound` の XPC code が未検証で、型付き分類が version 差で崩れる。実機採取で確認し、fixture メタデータに記録する。
- 過剰な pull でレート制限や帯域を使う。取得済みなら pull しない経路を先に確認する。
- ロールバック: 追加モジュールは 0026 から参照されるまで既定経路に接続されない。

## 変更履歴

`CHANGES.md` impact: yes

項目案:

- [ADD] macOS で Apple Container XPC による image pull と platform を考慮した参照解決を追加する

## 注記

- 参照: [src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（`pull_image` / `resolve_image_descriptor` / `normalize_image_reference` / `resolve_or_pull_macos`）、[src/core/client/image_config.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/image_config.rs)（index → manifest → config と platform 選択）、[src/core/client/container_cfg.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/container_cfg.rs)（`normalize_platform`）。
- 証跡: 実機の pull ログと fixture。fixture は 0024 の置き場に route / version メタデータ付きで保存する。
- 保守者の判断に委ねる点: pull の既定タイムアウト（upstream の 24 時間を上限として採用するか短い既定にするか）は、実測のダウンロード時間に基づいて決める。
- 関連: 0024（プロトコル）、0026（create への受け渡し）、0032（実機受入）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた
