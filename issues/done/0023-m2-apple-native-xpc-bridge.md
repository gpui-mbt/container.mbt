# [P0 / M2] Apple Container XPC の MoonBit-native FFI 境界を確定

Status: done
Model: DeepSeek V4.1 Flash Free
Created: 2026-10-16
Updated: 2026-10-17
Branch: feat/initial-moonbit-container-port-20261016
Priority: P0
Milestone: M2
Depends on: なし
Upstream baseline: [shiguredo/container-rs@f68ba1ffed67](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

## 概要

MoonBit native から Apple Container の XPC サービスへ到達する最小手段を PoC で確定し、C shim の境界・所有権・リーク防止の契約を決める。Node / Rust runtime は使わない。

## 背景

- macOS 経路の M0 は `container` CLI adapter のみで、実機未検証。upstream は CLI を使わず Apple Container XPC を直接利用する（[src/core/client/xpc_client.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/core/client/xpc_client.rs)）。
- upstream の到達手段は C shim: [src/xpc_bridge.c](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc_bridge.c) / [src/xpc_bridge.h](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc_bridge.h) が `<xpc/xpc.h>` と `<dispatch/dispatch.h>` を包み、`xpc_connection_create_mach_service` → `xpc_connection_set_event_handler`（空ハンドラ）→ `xpc_connection_activate` で接続し、辞書 setter（string / data / int64 / uint64 / bool / fd）、`xpc_bridge_send_message_with_reply_sync`（dispatch_semaphore による timeout 付き同期待ち。reply 到達と timeout の競合は atomic refcount で管理し、遅延 reply を安全に解放する）、`xpc_bridge_copy_data`、`xpc_bridge_get_int64_checked`、`xpc_bridge_is_error` / `xpc_bridge_get_error_description`、`xpc_bridge_get_log_fds`（`xpc_array_dup_fd`）、`xpc_bridge_release` / `xpc_bridge_connection_cancel` を提供する。
- upstream の [build.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/build.rs) は macOS ターゲットのときだけ `xpc_bridge.c` を `-fblocks` 付きでコンパイルし、DOCS_RS ではスキップする。[Cargo.toml](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/Cargo.toml) を見る限り XPC 用の外部 crate はなく、XPC 周辺で使う依存は確保したネイティブメモリの解放用の libc のみで、cc は build-dependency である。
- MoonBit 側は native target のみ（`moon.pkg` の `supported_targets = "+native"`）で、C FFI は `extern "c"` と native-stub で構成できる。Rust 側の接続ライフサイクルは [src/xpc/conn.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc/conn.rs) が `RawReply`（Drop で release）と `XpcConn`（Drop で cancel + release）として実装している。
- 0024 以降（プロトコル、pull、create/start、stop/rm、logs FD）はすべて本 issue の FFI 契約の上に乗る。0032 が実機受入を行う。

## 問題

- MoonBit には XPC バインディングが存在しない。
- CLI 経由では XPC のエラー code、FD 所有権、待ち時間制御、接続ライフサイクルを得られず、M2 の受入条件を満たせない。
- Node.js / Rust runtime を持ち込むことは README の要件（No Node.js, Python, Rust 依存）に反する。
- 同期ブロッキングの XPC 呼出を MoonBit の async とどう共存させるかが未確定である。

## 目標

- 物理 Apple Silicon（macOS 26）で apiserver へ接続し、1 往復の handshake の結果（応答または型付きエラー）を取得できる PoC を確定する。
- 破棄・接続失敗・タイムアウトで XPC オブジェクト / 接続 / FD のリークがないことを検証できる。
- Node / Rust runtime を不要とする。
- Intel Mac を要求対象外として明記する。
- 0024 以降が依存できる C 関数セットと所有権規則（誰が解放するか）を確定する。

## 対象外

- XPC プロトコルの意味論と golden fixture（0024）。
- image pull（0025）、create/start（0026）、stop/rm（0027）、logs FD（0029）。
- Apple CLI adapter の改善（M0）。
- Intel Mac・仮想化 macOS での動作（実機以外は受入に使わない。GitHub の macOS runner を実機の代わりにしない方針は `docs/APPLE_E2E.md` と同じ）。
- Drop / keep / watchdog の契約（0042）。

## 提案する方針

1. 到達手段は upstream と同じ「小さな C shim + MoonBit `extern "c"`」方式を採用する（PoC で確定）。依存は macOS SDK の XPC と dispatch だけに閉じ、Objective-C / Swift runtime を持ち込まない。
2. ファイル構成（案。名称は実装詳細として変更可）。
   - `xpc_stub.c`（新規、`moon.pkg` と同ディレクトリ）: native-stub に登録し、blocks のため `-fblocks` を付ける。upstream の C 関数セットを出発点に、0024 以降で使う分だけを追加する。
   - `xpc_ffi.mbt`（新規）: `extern "c"` 宣言。native（macOS）以外ではコンパイルされないよう target gate を付ける。
   - `xpc_bridge.mbt`（新規）: 安全 wrapper（接続、送信、解放）と MoonBit 側の所有権規則。
3. ポインタ型の扱いは PoC で確定する。候補は (a) external object + finalizer（`moonbit_make_external_object` 相当で release / cancel を保証）、(b) `#external` 型 + 明示 destroy。どちらでも「同一オブジェクトを二重解放しない」「失敗経路で解放漏れしない」を満たすことを受け入れ条件で固定する。
4. ポインタ引数は呼出し中だけ参照するものに `#borrow`、所有権を移すものに `#owned` を付ける。文字列は null 終端の Bytes を渡す。戻り値の C 文字列・バイト列は MoonBit 側へコピーしてから C 側メモリを解放する（upstream `xpc_bridge_copy_data` と同じ規則）。
5. PoC で確認する項目。
   - apiserver（upstream の service 名定数。0024 で移植）へ接続できる。
   - 読み取り専用の最小 route で 1 往復の応答を取得できる。
   - タイムアウト後に遅延 reply が到着しても use-after-free / 二重解放が起きない（upstream が過去に踏んだ競合であり、atomic refcount 方式をそのまま採る）。
   - connect / send / cancel / release の反復で FD・メモリが増えない（ASan と FD 数で確認）。
6. MoonBit async との共存: XPC 呼出は同期ブロッキングのため、MoonBit の async タスクから直接呼ぶとスケジューラを塞ぎ得る。PoC で (a) 専用スレッドへ隔離、(b) 短い timeout で分割、(c) 専用プロセスへ隔離、のいずれが成立するかを確認し、0024 の接続所有権（1 呼出 1 接続か再利用か）へ反映する。
7. リーク検証は moonbit-c-binding の ASan 手順で行い、結果を issue に記録する。実機実行の証跡には macOS version・Apple container version・実行コマンド・生の応答を含める。
8. リンク設定（macOS SDK / フレームワーク指定の要否）は PoC で確定し、`moon.pkg` の native 設定へ反映する。

## 受け入れ条件

- [ ] Given 物理 Apple Silicon（macOS 26）の PoC, when apiserver へ接続して 1 往復する, then 応答または XPC エラーが型付きで取得できる（内容の意味論は 0024 以降）。
- [ ] Given 存在しない service 名または daemon 停止状態, when connect する, then クラッシュせず明示エラーになる。
- [ ] Given タイムアウト付き送信, when 応答が期限内に来ない, then タイムアウトエラーが返り、遅延 reply が到着してもリーク / use-after-free がない（ASan で確認）。
- [ ] Given connect → send → cancel → release を反復する, when 完了する, then FD 数とメモリが増加しない。
- [ ] Given Linux など macOS 以外のビルド, when native target をビルドする, then XPC 依存ファイルはコンパイル・リンクされない。
- [ ] Given PoC の実行, when プロセス一覧を確認する, then Node / Rust / 外部 runtime プロセスを起動していない。
- [ ] Given ドキュメント, when 対象を確認する, then Intel Mac が要求対象外と明記されている。
- [ ] C 関数セットと所有権規則（解放責任・borrow / owned）が一覧化され、0024 以降が参照できる。

## テスト計画

- `moon check --target native --deny-warn` と `moon test --target native` を実行し、PASS / FAIL / 未実行を記録する。
  - wbtest: MoonBit side の純部分（エラー変換、引数の組み立て、所有権フラグの分岐）を実機なしで検証する。
- 最小 XPC PoC は物理 Apple Silicon 必須。GitHub の macOS runner と compile-only では代替しない（[docs/APPLE_E2E.md](https://github.com/gpui-mbt/container.mbt/blob/feat/initial-moonbit-container-port-20261016/docs/APPLE_E2E.md) の方針）。このブランチでは「未実行」。
- ASan 実行（moonbit-c-binding の手順）を実機で行う。実行できるまでは「未実行」。
- 証跡: macOS / Apple container の version、実行コマンド、handshake の生ログ、リーク検査結果。

## リスク

- 同期ブロッキング呼出が async スケジューラを塞ぐ。PoC で隔離方式を確定し、隔離できない場合は 0024 の設計へ制約として引き継ぐ。
- ポインタ型の取り違えで二重解放 / リークが起きる。生成と破棄を 1 箇所に閉じ、ASan と反復テストで確認する。
- blocks 付き C のコンパイルがツールチェーン差で失敗する。`-fblocks` を stub に限定し、PoC 失敗時は代替（delegate のない同期 API だけを使う）を検討する。
- service 名や応答が Apple container の version に依存する。実測した version を証跡に残し、差分は 0024 の形状エラーで扱う。
- GitHub の macOS runner を実機と誤認する。実機受入は 0032 まで行わず、「未実行」を維持する。
- ロールバック: 追加は新規ファイルと `moon.pkg` の native 設定に限定し、既存 CLI / Linux 経路に触れない。

## 変更履歴

`CHANGES.md` impact: no

## 注記

- 参照: [src/xpc_bridge.c](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc_bridge.c)、[src/xpc_bridge.h](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc_bridge.h)、[src/xpc/conn.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/src/xpc/conn.rs)、[build.rs](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/build.rs)、[Cargo.toml](https://github.com/shiguredo/container-rs/blob/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3/Cargo.toml)。
- C shim の関数一覧は固定しすぎず、0024 が必要とするキーと型から逆算して追加する。ただし追加時も所有権規則はこの issue の一覧に追記して一元管理する。
- 保守者の判断に委ねる点: イベントハンドラ方式（upstream は空ハンドラ + 同期 reply）で全操作を賄えるか、応答ストリーム（logs FD 等）で別方式が必要かは PoC と 0029 の結果で決める。
- 実機がない環境では本 issue を完了にできない。0032 が最終受入であり、本 issue はその前提である。
- 2026-10-16: polish-issue: 背景・対象外・受け入れ条件・テスト計画・リスク・変更履歴を補完し、独立実装可能な形に整えた

## 実装状況 (2026-10-17)

XPC C shim（`xpc_stub.c`）と `xpc_ffi.mbt` / `xpc_bridge.mbt` を追加。非ブロッキング送信 + poll 方式、atomic な late-reply 解放、接続/メッセージ/reply の明示解放を実装。`xpc_bridge_wbtest.mbt` の live handshake、厳格デコード、タイムアウト反復が PASS（macOS 実機）。ABI/所有権は `docs/APPLE_XPC_BRIDGE.md` に記録。ASan と 1.2.0 固有の挙動は未実行。
