# Regression tests

Run `./scripts/test.sh` from the repository root. It uses Swift Testing with the required plugin/framework paths when only Command Line Tools are installed; full Xcode can also use `swift test`.

The suite covers:

- Scan completion order, late progress, cancellation, overlapping rescans, and stale callbacks.
- Hidden files, packages, symlinks, hard links, sparse allocation, missing/unreadable paths, and bounded progress updates.
- App bundle measurement, related-file matching boundaries, and disjoint cleanup candidates.
- Protected roots, running apps, ancestor symlinks, explicit external scopes, nested selections, stale review identity, and per-item Trash failures.
- Recorded Trash restoration, untrusted sources, and refusing to overwrite a replacement file.
- SQLite persistence, indexed browsing/search/categories, comparison/retention, batched cancellation cleanup, and keeping history when indexes are cleared.
- Reopening a saved session without a scan and preserving it when its root becomes unavailable.
- Treemap area, bounds, and non-overlapping geometry at different aspect ratios.

Tests create disposable filesystem fixtures and inject Trash operations. They do not scan the user's disk, delete user data, or empty the real Trash. Live UI verification is separate from the regression suite.

The expanded suite also covers exact duplicate hashing, keeper protection, file changes between verification and cleanup, cache-only goal planning, reused Trash paths, SQLite read errors, and refreshing an open indexed descendant after a new scan.
