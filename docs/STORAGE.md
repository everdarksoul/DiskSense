# Measurements, saved scans and permissions

Physical BSD traversal counts allocated blocks, hidden files and package contents. It does not follow symlinks or request cloud downloads, and directory identities prevent repeated APFS alias traversal. Scans remain on the starting filesystem. Unreadable paths are reported as partial coverage.

Allocated totals are not a promise of reclaimed space: APFS clones, snapshots, purgeable storage and Trash all affect volume usage.

Saved data lives in `~/Library/Application Support/DiskSense` in an owner-only directory. Memory caches retain at most 24 folders and 50,000 rows. Each index normally retains up to 150,000 entries or 32 MiB of indexed path text, plus up to 10,000 immediate root items needed for navigation. A banner explicitly identifies limited coverage; folder measurement continues even when indexing stops. Search and duplicate checks then cover only indexed files—choose a smaller root for full coverage. Large folder queries show at most 10,000 indexed rows.

Retention keeps up to two scans per location and four globally, with a 256 MiB live-page target that evicts older indexes or reduces the current index. SQLite WAL/slack and unusually large immediate root entries can temporarily exceed the target; maintenance compacts free pages. Cleanup history is preserved. The toolbar menu can reveal local data or clear saved indexes. The 0.4 upgrade rebuilds incompatible pre-0.4 indexes to remove incorrect historical alias totals; user files, inventory and cleanup history are kept.

Full Disk Access is optional for readable folders and needed for protected data. Local ad-hoc replacements may invalidate an existing approval even while its toggle remains on. Stable Developer ID signing is a production release requirement.


The public name changed from DiskSense to LintGoblin in 0.5. The bundle identifier and local data folder remain unchanged so existing history and settings stay available.
