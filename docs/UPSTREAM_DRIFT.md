# Upstream revision drift (issue 0053)

Pinned baseline: `shiguredo/container-rs@f68ba1ffed67c9c4e9abdb39212835d50d7afcf3`
(develop, 2026-10-07). Do not move the pin without a dedicated change and
approval.

## Procedure

1. Fetch develop into a temporary checkout (never into this worktree):
   ```sh
   git clone --filter=blob:none https://github.com/shiguredo/container-rs.git /tmp/container-rs
   git -C /tmp/container-rs checkout f68ba1ffed67
   git -C /tmp/container-rs fetch origin develop
   git -C /tmp/container-rs log --oneline f68ba1ffed67..origin/develop
   git -C /tmp/container-rs diff --stat f68ba1ffed67..origin/develop
   ```
2. Split the diff into API (public signatures, `src/lib.rs` exports) and
   behavior (tests, `CHANGES.md`, docs).
3. Classify each item: `[ADD]` API addition, `[FIX]` bug fix, `[CHANGE]`
   incompatible behavior, `[UPDATE]` internal/other, unsupported (this
   port does not take it; record why), or none.
4. Map each item to an existing issue/fixture or a new issue. A revision
   bump must update the issue's Upstream baseline and every fixture that
   cites it (single revision per fixture).
5. Incompatible changes require a dedicated issue, approval, and a
   migration plan; do not absorb them into an unrelated change.
6. Re-run the affected [conformance fixtures](CONFORMANCE.md) and record
   the result separately per revision.

## Comparison record: 2026-10-17

- Pinned: `f68ba1ffed67` (2026-10-07).
- develop HEAD at comparison: `926aceb` (`rustdoc の private 項目へのリンク警告を修正する`).
- Commits: 5 (`git rev-list --count` = 5).
- Diff: 16 files, +54/−14. Changes are module-file renames
  (`mod.rs` → `<module>.rs`), MSRV 1.95, a healthcheck adjustment, rustdoc
  link fixes, and small internal logging/watchdog changes.
- Public API: **no changes detected** in `src/lib.rs` or exported
  signatures.
- Classification: `[UPDATE]` internal layout/MSRV/rustdoc;
  `[FIX]` healthcheck/logging details; `[CHANGE]` none.
- Action: no pin bump and no new issue. The affected healthcheck/logging
  behavior is already documented as a MoonBit deviation where relevant;
  re-evaluate when the upstream `CHANGES.md` announces a user-visible
  change.
