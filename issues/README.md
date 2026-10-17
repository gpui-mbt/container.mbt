# container.mbt porting backlog

作成日: 2026-10-16  
位置づけ: issue ではなく索引（バックログ一覧）  
対象: `feat/initial-moonbit-container-port-20261016` (Draft PR #1)  
Upstream pinned baseline: [shiguredo/container-rs `f68ba1ffed67c9c4e9abdb39212835d50d7afcf3`](https://github.com/shiguredo/container-rs/tree/f68ba1ffed67c9c4e9abdb39212835d50d7afcf3)

このファイルは issue ではなく索引。issue の本体は状態ディレクトリ（`open/` = 未着手、`polished/` = 実装可能、`doing/` = 着手中、`done/` = 完了、`rejected/` = 却下）配下の Markdown として管理し、検証は `local_issues.py` の contract（必須フィールドと必須セクション）に従う。番号はタスク識別子であり GitHub Issue 番号ではない。M0 の CLI 版をそのまま完全互換とみなさず、上流の *確認できる* API・挙動を段階的に再現する。

## 運用ルール

1. **P0 を優先**。依存先が未完了なら先に扱う。非対応機能を暗黙に無視しない。
2. 作業時は担当 Issue のチェックボックスと実測証跡を記録。PASS / FAIL / 未実行を混同しない。
3. M1 は Linux Docker Engine native（CLI 非依存）、M2 は Apple Silicon XPC（CLI 非依存）を別に受入する。
4. Mac physical-host E2E を VM/CI compile-only で代替しない。CI green + 独立 approve 相当レビューを完了条件とする。
5. ユーザー所有 container/ボリュームと未コミット作業を破棄しない。テストは固有 ID/label に限定して掃除する。
6. upstream の revision を更新する時は関連 Issue と conformance fixture に根拠を残す。

## タスク一覧

### M0 — CLI M0 受入・安全性 (5件)

- [x] [0001 CLI run が ID を返す前に失敗した場合の orphan 回収](./done/0001-m0-run-failure-orphan-cleanup.md) — P0
- [ ] [0002 Apple Silicon 実機で M0 CLI smoke を完走する](./polished/0002-m0-apple-cli-physical-e2e.md) — P0 / deps: 0001
- [ ] [0003 Apple CLI 固定 published port の TCP 到達を検証](./polished/0003-m0-apple-host-tcp-forwarding.md) — P1 / deps: 0002
- [x] [0004 CLI adapter の非対応設定を副作用前に明示拒否する](./done/0004-m0-runtime-option-preflight.md) — P1
- [x] [0005 CLI 起動・readiness・cleanup の回帰テストを固定する](./done/0005-m0-cli-lifecycle-regression.md) — P1 / deps: 0001

### M1 — Linux Docker Engine 直接接続 (17件)

- [x] [0006 Node/Rust に依存しない Docker Unix socket transport](./done/0006-m1-docker-unix-socket-transport.md) — P0
- [x] [0007 Docker HTTP/1.1 応答・chunked・stream decoder を実装](./done/0007-m1-docker-http-framing-parser.md) — P0 / deps: 0006
- [ ] [0008 Docker API version・daemon readiness の判定を追加](./polished/0008-m1-docker-daemon-version-preflight.md) — P1 / deps: 0006, 0007
- [x] [0009 Docker Engine API の image pull と progress/error を実装](./done/0009-m1-native-image-pull.md) — P0 / deps: 0006, 0007
- [x] [0010 Docker Engine API の create/start と request serialization](./done/0010-m1-docker-create-start.md) — P0 / deps: 0006, 0007, 0009
- [x] [0011 Docker inspect/stop/rm/wait と冪等 lifecycle を移植](./done/0011-m1-docker-inspect-stop-rm-wait.md) — P0 / deps: 0010
- [x] [0012 Docker exec create/start と stdout/stderr 多重化を移植](./done/0012-m1-docker-exec-attach.md) — P0 / deps: 0011, 0007
- [x] [0013 Docker stdout/stderr の follow/attach と有界取得](./done/0013-m1-docker-log-stream.md) — P1 / deps: 0011, 0007
- [x] [0014 Docker の動的 host port を IPv4/IPv6 inspect で解決](./done/0014-m1-dynamic-published-ports.md) — P0 / deps: 0011
- [x] [0015 Container bridge IP と network 情報を正規化](./done/0015-m1-bridge-ip-inspection.md) — P1 / deps: 0011
- [x] [0016 Docker registry 認証と秘密情報保護](./done/0016-m1-registry-auth-config.md) — P1 / deps: 0009
- [x] [0017 Docker API ステータスと失敗分類を実装](./done/0017-m1-engine-http-errors.md) — P1 / deps: 0007
- [x] [0018 Engine transport の deadline・取消・再試行を一元化](./done/0018-m1-engine-deadline-cancel.md) — P0 / deps: 0006, 0007
- [x] [0019 CLI と直結 API の移行方針・capability gate](./done/0019-m1-cli-adapter-migration-policy.md) — P1 / deps: 0010
- [x] [0020 Linux daemon 直結の起動から削除までの E2E](./done/0020-m1-linux-native-e2e.md) — P0 / deps: 0010, 0011, 0012, 0013, 0014, 0018
- [x] [0021 Linux でプロセスクラッシュ後の残存検出と限定回収](./done/0021-m1-linux-process-crash-recovery.md) — P1 / deps: 0020
- [x] [0022 Podman 等 Engine API 互換環境の互換境界を記録](./done/0022-m1-docker-api-compatible-runtimes.md) — P2 / deps: 0020

### M2 — macOS Apple Container XPC (10件)

- [ ] [0023 Apple Container XPC の MoonBit-native FFI 境界を確定](./polished/0023-m2-apple-native-xpc-bridge.md) — P0
- [ ] [0024 XPC request/response・型/バージョン契約を移植](./polished/0024-m2-xpc-protocol-contract.md) — P0 / deps: 0023
- [ ] [0025 Apple XPC image pull・参照/manifest の確認](./polished/0025-m2-xpc-image-pull.md) — P1 / deps: 0024
- [ ] [0026 Apple XPC container create/start と rollback](./polished/0026-m2-xpc-create-start.md) — P0 / deps: 0024, 0025
- [ ] [0027 Apple XPC stop/remove と idempotent cleanup](./polished/0027-m2-xpc-stop-remove.md) — P0 / deps: 0026
- [ ] [0028 Apple XPC exec と stdout/stderr/exit code を取得](./polished/0028-m2-xpc-exec.md) — P1 / deps: 0026, 0024
- [ ] [0029 Apple XPC logs の FD 所有権と停止処理](./polished/0029-m2-xpc-logs-fd-ownership.md) — P0 / deps: 0026, 0024
- [ ] [0030 Apple XPC port mapping・bridge IP・host gateway](./polished/0030-m2-xpc-ports-network-inspect.md) — P1 / deps: 0026
- [ ] [0031 Apple XPC bind/volume/tmpfs とコピーの互換検証](./polished/0031-m2-xpc-mount-copy.md) — P1 / deps: 0026
- [ ] [0032 macOS 26 Apple Silicon の XPC native 受入試験](./polished/0032-m2-apple-native-xpc-e2e.md) — P0 / deps: 0026, 0027, 0028, 0029, 0030

### M3 — 機能パリティ・品質・配布 (22件)

- [x] [0033 Linux archive API による with_copy_to の起動前投入](./done/0033-m3-copy-to-before-start.md) — P1 / deps: 0010, 0011
- [x] [0034 copy_file_from でファイルを安全に取り出す](./done/0034-m3-copy-from-bounded-archive.md) — P1 / deps: 0011, 0007
- [x] [0035 tar 作成/展開と path traversal の安全性](./done/0035-m3-tar-path-security.md) — P0 / deps: 0033, 0034
- [x] [0036 WaitFor::http と HTTP status/header/body 条件を移植](./done/0036-m3-http-readiness.md) — P1 / deps: 0014
- [x] [0037 Healthcheck builder と healthy/unhealthy wait を実装](./done/0037-m3-healthcheck-readiness.md) — P1 / deps: 0011
- [x] [0038 WaitFor::exit と exec 待機条件を移植](./done/0038-m3-exit-cmd-wait.md) — P1 / deps: 0011, 0012
- [ ] [0039 環境変数待ちと複数 ready conditions の意味論](./polished/0039-m3-advanced-readiness.md) — P2 / deps: 0036, 0037, 0038
- [ ] [0040 LogConsumer 継続配信と backpressure を実装](./polished/0040-m3-log-consumer-backpressure.md) — P1 / deps: 0013
- [ ] [0041 stop_with_timeout と exit code 語義を揃える](./polished/0041-m3-graceful-stop-exit-code.md) — P1 / deps: 0011, 0027
- [ ] [0042 所有 container の Drop/keep/watchdog cleanup 契約](./polished/0042-m3-drop-keep-watchdog.md) — P0 / deps: 0021, 0032
- [ ] [0043 SyncRunner と同期 Container 操作の安全な設計](./polished/0043-m3-sync-runner-facade.md) — P2 / deps: 0011
- [ ] [0044 tmpfs size/mode・volume/read-only/bind の詳細互換](./polished/0044-m3-advanced-mounts.md) — P1 / deps: 0010, 0026
- [ ] [0045 hostname・ExtraHost・network を API と実行経路に追加](./polished/0045-m3-hostname-extra-hosts-networks.md) — P1 / deps: 0010
- [ ] [0046 privileged・capability・shm・init 等を移植](./polished/0046-m3-resource-security-options.md) — P1 / deps: 0010
- [ ] [0047 Mac 専用 kernel/ssh/masked/readonly path オプション](./polished/0047-m3-macos-special-options.md) — P2 / deps: 0024, 0026
- [ ] [0048 ImageExt・ContainerRequest の override 契約を整える](./polished/0048-m3-image-request-api-parity.md) — P1 / deps: 0010
- [ ] [0049 公開エラー型と失敗分類の一貫性を検証](./polished/0049-m3-typed-errors-failure-matrix.md) — P1 / deps: 0017, 0024
- [ ] [0050 Rust upstream と MoonBit の同一 fixture 比較基盤](./polished/0050-m3-conformance-oracle.md) — P0 / deps: 0020, 0032
- [ ] [0051 Mooncakes consumer から使える公開 API・文書・配布](./polished/0051-m3-consumer-docs-publish.md) — P2 / deps: 0048
- [ ] [0052 Linux/Mac の実証と compile-only を区別する CI](./polished/0052-m3-ci-platform-matrix.md) — P1 / deps: 0020, 0032
- [ ] [0053 pinned upstream からの API/挙動 drift を追跡する](./polished/0053-m3-upstream-revision-drift.md) — P2 / deps: 0050
- [ ] [0054 argv/JSON/path/ログの不正入力と資源リークを系統検証](./polished/0054-m3-input-validation-and-leak-fuzz.md) — P1 / deps: 0010, 0024

## 着手順の目安

- M0: 0001 → 0002 → 0003、並行で 0004/0005。
- M1 最短経路: 0006 → 0007 → 0009 → 0010 → 0011 → 0012/0013/0014 → 0020。
- M2 最短経路: 0023 → 0024 → 0025/0026 → 0027/0028/0029/0030 → 0032。
- M3: 0033–0054 を並行作業に分割。ただし 0050 の conformance 証拠は最終判定の基礎。

GitHub Draft PR: https://github.com/gpui-mbt/container.mbt/pull/1
