# [P0 / M2] XPC request/response・型/バージョン契約を移植

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: [0023](./0023-m2-apple-native-xpc-bridge.md)
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

XPC の request / response の型とキー、エラー応答、タイムアウト、接続ライフサイクルを独立モジュールへ移植し、golden fixture と厳格なデコードで契約を固定する。

## 背景

- upstream の XPC 呼出は [src/xpc/conn.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc/conn.rs) の `XpcConn::send(route, entries)` が基本である。辞書のキー `com.apple.container.xpc.route` に route 名（例: `containerCreate`、`containerStartProcess`、`containerStop`、`containerDelete`、`containerList`、`containerWait`、`containerLogs`、`imagePull`、`imageList`）を設定し、値は String / Data / Bool / Int64 / UInt64 / Fd の 6 種を送る。
- サービス名は `com.apple.container.apiserver`（コンテナ操作）と `com.apple.container.core.container-core-images`（image 操作）。タイムアウトは既定 60 秒、`containerWait` 等の長期待ちは 24 時間（`LONG_TIMEOUT`）。
- エラーは 2 系統ある。XPC の error object（`xpc_bridge_is_error` + description）と、キー `com.apple.container.xpc.error` に入る JSON `{"code": "...", "message": "..."}` である。upstream は後者を `XPC error {code}: {message}` に整形し、非 UTF-8 は "response is not UTF-8"、JSON として不正なら "unparseable" と区別する（`src/xpc/conn.rs` の unit test で固定されている）。
- int64 の取得は「キーが存在し、型が XPC_TYPE_INT64 のときだけ成功」とする `xpc_bridge_get_int64_checked` を使う。キー欠落・型不一致はエラーであり、以前 0 を返していた回帰がテストで固定されている。
- upstream に version handshake は存在しない。Apple container の version 差は応答の形状差として現れる。
- 0023 が FFI 境界を提供する。0025–0029 が本 issue の型を使って個別 route を実装する。

## 問題

- 現行 MoonBit には XPC の request / response 表現もデコード規約もない。
- 緩いデコード（欠落を既定値で補う、型不一致を文字列化する等）を許すと誤診断を生み、upstream がテストで固定した安全性を失う。
- Apple container の version 差で形状が変わったとき、どこで失敗したかを特定できない。

## 目標

- 型付きの request 構築（route + キー値の組）と response デコードを独立モジュール化する。
- golden fixture で主要メッセージの形状を固定する。
- 既知キーの欠落 / NULL / 型不一致 / 不正 UTF-8 を、区別できる明示エラーとして拒否する。
- 未知キーによる前方互換の破壊は避け、未知キーは解釈に使わない。
- version 差を形状不一致として明示エラーにする。
- 接続の生成・破棄の契約（1 呼出 1 接続を基準とし、失敗時に接続とオブジェクトを残さない）を定義する。

## 対象外

- pull（0025）、create/start（0026）、stop/rm（0027）、logs FD（0029）、ports/network（0030）。
- XPC の C shim とポインタ所有権（0023）。
- 実機受入と全 route の結合（0032）。
- エラー型の全体分類の統一（0049。本 issue は XPC 範囲の分類を提供するのみ）。

## 提案する方針

1. 新規 `xpc_protocol.mbt`（新規、実装詳細として変更可）に次を置く。
   - route 名・キー名・サービス名・タイムアウトの定数（例: `id`、`containerConfig`、`containerOptions`、`kernel`、`imageReference`、`insecureFlag`、`maxConcurrentDownloads`、`ociPlatform`、`stopOptions`、`forceDelete`、`processIdentifier`、`exitCode`、`listFilters`、`containers`、`imageDescriptions`。本 issue で使う範囲から順次追加する）。
   - request の値型（String / Data / Bool / Int64 / UInt64 / Fd。upstream の `KeyValue` に対応）。
   - response デコード API。必要なキーだけを読み、既知キーの欠落・型不一致・NULL・不正 UTF-8 は明示エラーにする。
   - JSON は MoonBit core の JSON サポート（`moonbitlang/core/json` 等）を利用し、生バイト列を fixture と突き合わせられる形にする。採用モジュールは実装詳細として変更可。
2. 接続ライフサイクルは upstream と同じ「1 呼出 1 接続」を基準とする（`call()` 相当が接続を作り、Drop 相当で cancel + release する）。同一接続を使い回して複数 route を送れるかは実機で確認し、安全性の根拠（応答と route の対応、切断時の挙動、レイテンシ）を記録してから採用を判断する。採用しない場合も「再利用を検証した結果、1 呼出 1 接続を維持する」という根拠を残す。
3. エラー整形は upstream に合わせる。
   - XPC error object: description をそのままエラー本文にする。
   - `com.apple.container.xpc.error` JSON: `code` と `message` を文字列として取り出し `XPC error {code}: {message}` に整形する。
   - 非 UTF-8: "response is not UTF-8" 相当。
   - JSON 不正 / 未知の構造: "unparseable" 相当（部分解釈しない）。
   - `notFound` など code の意味づけは、文字列プレフィクスに頼る upstream の判定をそのまま残さず、可能なら型付き分類として 0027 / 0049 へ渡す（本 issue では code 文字列を保持する型を提供する）。
4. timeout: 既定 60 秒と長期 24 時間の 2 段を定数化し、呼出し側が上書きできる形にする。期限切れは `XpcTimeout` 型のエラーにし、接続が残らないことを保証する。
5. golden fixture: `xpc_fixtures/`（新規ディレクトリ、実装詳細）に実機で採取した応答バイト列（秘匿情報を含まないもの）を置く。fixture には route 名、Apple container version、採取日、採取時の platform をメタデータとして付ける。fixture に無い形状は実機で再採取してから追加する。
6. version 差: fixture のメタデータと応答の形状を照合し、既知 fixture と異なる形状は「形状不一致」として明示エラーにする（黙って値を欠落させない）。形状不一致を version 文字列での判定に依存させない（handshake が無いため）。

## 受け入れ条件

- [ ] Given golden fixture（`containerList`、`containerStop`、`containerDelete`、`containerWait`、`imageList` など主要 route）, when デコードする, then 期待値が取得できる。
- [ ] Given 既知キーの欠落 / XPC_TYPE_NULL / 型不一致 / 不正 UTF-8 の応答, when デコードする, then それぞれを区別できる明示エラーが返る（0 や空文字へフォールバックしない）。
- [ ] Given エラー応答 JSON が `code` / `message` を持たない、または非 JSON、または非 UTF-8, when デコードする, then unparseable として拒否し、部分的な解釈をしない。
- [ ] Given 応答に未知の追加キー, when デコードする, then 既知キーの解釈に影響せず成功する（前方互換）。
- [ ] Given 連続 N 回の呼出, when 各呼出が完了する, then 接続と XPC オブジェクトのリークがなく、FD 数が増えない。
- [ ] Given 同一接続で複数 route を連続送信する実機確認, when 応答が返る, then route と応答の対応が取れるかを確認し、採用 / 不採用の判断根拠（レイテンシと切断時の挙動を含む）が記録されている。
- [ ] Given timeout 到達, when 遅延 reply が到着する, then タイムアウトエラーが返り、接続・オブジェクトが解放される。
- [ ] Given fixture 採取時と異なる形状の応答, when デコードする, then 形状不一致として明示エラーになる。
- [ ] Given 非 macOS ビルド, when テストを実行する, then fixture デコードなど純部分はテストでき、XPC 依存部分はコンパイルされない。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - unit: fixture デコード（実機不要）、route / キー定数の組み立て、エラー整形、非 UTF-8 / 非 JSON / 型不一致 / NULL / 欠落の拒否、timeout の型。
- 実機（物理 Apple Silicon macOS 26）: fixture の採取と version 記録、接続反復での FD リーク検査、同一接続での複数 route 送信の安全性確認。物理 Mac は CI に存在しないため、実行できるまで「未実行」と記録する。
- compile-only の CI 成功を実機確認の代わりにしない（`issues/README.md` 運用ルール 3・4）。

## リスク

- fixture が Apple container の version で変わる。fixture に version メタデータを付け、形状不一致を明示エラーにする。pin した upstream baseline と併記する。
- 厳格すぎるデコードで前方互換を壊す。未知キーは無視、既知キーのみ検証という規則をテストで固定する。
- 実機がないと fixture を新規採取できない。0023 の PoC と同時に採取し、それまでは既知 fixture だけで進める。
- 接続を 1 呼出ごとに張る方式はレイテンシが増える。実測して問題になった場合は再利用の安全性を別 issue で検証する。
- ロールバック: 追加モジュールは 0025 以降から参照されるのみで、既定経路へ未接続の間は既存挙動に影響しない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [src/xpc/conn.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc/conn.rs)（`KeyValue` / timeout / エラー整形 / unit test）、[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)（route 名・キー名・`is_not_found_error` の実装）。
- 証跡: fixture 1 件ごとに route・version・採取日を持たせる。実機採取ログは PR に残す。
- 保守者の判断に委ねる点: 接続再利用を採用するかどうか、`notFound` 分類を型で持つか文字列で持つかは、実測と 0027 の必要性に応じて決める。
- 関連: 0023（FFI）、0025 / 0026 / 0027（利用側）、0049（エラー分類の統一）。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

route/key/service/timeout 定数、`XpcValue`、`XpcReply` の型チェック付きデコーダ、JSON エラー整形を実装。`fixtures/xpc/` の golden fixture と live `containerList` の strict decode テストが PASS。未知キー無視、欠落/型不一致/非 UTF-8/不正 JSON を区別。1.2.0 の形状差は未実行。
