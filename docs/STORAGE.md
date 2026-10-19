# Measurements, saved scans and permissions

Physical BSD traversal counts allocated blocks, hidden files and package contents. It does not follow symlinks or request cloud downloads, and directory identities prevent repeated APFS alias traversal. Scans remain on the starting filesystem. Unreadable paths are reported as partial coverage.

Allocated totals are not a promise of reclaimed space: APFS clones, snapshots, purgeable storage and Trash all affect volume usage.

## Complete indexing without repeated paths

Starting in 0.5.1, the SQLite catalog stores a parent directory path once and references it by an integer from each file row. Files store a basename and metadata; complete paths are reconstructed for results. Scan identifiers in catalog rows are integers too. The writer retains at most 4,096 directory IDs in memory; SQLite holds the full directory map.

There is no default file-count or path-text indexing cutoff. The former 150,000-entry / 32 MiB path-text limits were inadequate for a normal disk and are removed. Folder queries return every indexed child. Search considers the full readable index and displays up to 200 results; duplicate checking uses all eligible candidates, independently of that display limit.

Memory navigation caches retain at most 24 folders and 50,000 rows. Retention keeps up to two scans per location and four globally. A 256 MiB soft history budget evicts older snapshots; it never trims the newest scan. A single complete disk index can exceed that budget. SQLite WAL and free pages add temporary overhead; maintenance checkpoints and compacts when useful. Cleanup history is preserved independently.

Saved data lives in `~/Library/Application Support/DiskSense` in an owner-only directory. The toolbar can reveal this directory or clear cached scan indexes. User files and cleanup history are kept when indexes are cleared.

## Upgrading older indexes

The 0.5.1 upgrade builds a new `scans-v5.sqlite` catalog. Old indexes are retired only after their cleanup receipts have been copied successfully. The most recently scanned root from v4 is remembered and rebuilt once; existing inventory is reused. Old incomplete indexes cannot recover omitted files without a new scan. No user files are removed during this migration.

Full Disk Access is optional for readable folders and needed for protected data. Local ad-hoc replacements may invalidate an existing approval even while its toggle remains on. Stable Developer ID signing is a production release requirement. Full Disk Access does not grant administrator write privileges.

The public name changed from DiskSense to LintGoblin in 0.5. The bundle identifier and local data folder retain their original names for compatibility.
