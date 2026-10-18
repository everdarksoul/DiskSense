# DiskSense

**Find what takes space. Review what can go. Keep a way back.**

A native, local-first macOS disk explorer and cleanup utility, written in SwiftUI and AppKit. MIT licensed. No accounts, telemetry, uploads, or runtime network access.

**Release status: 0.4 public beta.** The core is covered by fixture tests and local UI checks. Public production sign-off still requires Developer ID notarization, passing cross-Mac CI, and beta feedback. This repository does not claim category-leading speed or guaranteed reclaimed bytes.

## Explore

- Size-proportional Space Map and a selectable list share folder navigation, back/forward history, a folder chooser, and a view switcher.
- Open a different folder directly from the map. Indexed folders load from SQLite; unindexed folders can be measured live without forcing you into another screen.
- Recently visited map folders stay in a bounded cache. Returning to a previously scanned root reopens its saved results; choose Rescan when you want fresh measurements.
- Search paths by name, size, type and age. Compare top-level changes between retained scans of the same location.
- Command-K switches tools. Command-O opens a folder. Command-F opens search. Command-R refreshes folder measurements.

## Make room deliberately

- **Make Room** proposes editable 1/5/10 GB plans from cache and generated-build candidates. It reports shortfalls honestly.
- **Applications** measures complete app bundles and lists possible related files. Related data is not preselected during uninstall.
- **Duplicates** verifies eligible local files of at least 1 MiB using streaming SHA-256. Symlinks, hard links, placeholders, app/managed-library contents, Git and Trash are excluded. Selected files and an unselected original are checked again before review and confirmation.
- **Activity** records successes/failures and offers restore for recorded, identity-verified Trash destinations. Restore refuses to overwrite an existing destination. Legacy or mismatched receipts require Finder.
- Every cleanup opens a separate review. DiskSense moves reviewed items to Trash; it never empties Trash. Close the associated apps before removing their caches.

The Apps and Cleanup inventory has its own timestamp and refresh control. Changing or refreshing the explored folder does not need to rebuild that inventory.

## Orbit

Click the Orbit mark or menu-bar icon for a compact storage panel with current available capacity, scan progress and shortcuts. The animated mark respects Reduce Motion.

## Honest measurements and bounded storage

Physical BSD traversal counts allocated blocks, hidden files and package contents. It does not follow symlinks or request cloud downloads, and directory identities prevent repeated APFS alias traversal. Scans remain on the starting filesystem. Unreadable paths are reported as partial coverage.

Allocated totals are not a promise of reclaimed space: APFS clones, snapshots, purgeable storage and Trash all affect volume usage.

Saved data lives in `~/Library/Application Support/DiskSense` in an owner-only directory. Memory caches retain at most 24 folders and 50,000 rows. Each index normally retains up to 150,000 entries or 32 MiB of indexed path text, plus up to 10,000 immediate root items needed for navigation. A banner explicitly identifies limited coverage; folder measurement continues even when indexing stops. Search and duplicate checks then cover only indexed files—choose a smaller root for full coverage. Large folder queries show at most 10,000 indexed rows.

Retention keeps up to two scans per location and four globally, with a 256 MiB live-page target that evicts older indexes or reduces the current index. SQLite WAL/slack and unusually large immediate root entries can temporarily exceed the target; maintenance compacts free pages. Cleanup history is preserved. The toolbar menu can reveal local data or clear saved indexes. The 0.4 upgrade rebuilds incompatible pre-0.4 indexes to remove incorrect historical alias totals; user files, inventory and cleanup history are kept.

Full Disk Access is optional for readable folders and needed for protected data. Local ad-hoc replacements may invalidate an existing approval even while its toggle remains on. Stable Developer ID signing is a production release requirement.

## Build and test

The app targets macOS 13+. Use Swift 6 on macOS 14+ for tests; the Swift Testing runtime supplied by current tools requires a newer OS than the app's deployment target.

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The test script supports full Xcode and Command Line Tools-only installations. The release script builds an optimized app, generates its icon, verifies the signature, and writes `.build/Distribution/DiskSense.app` and `DiskSense-0.4.0.zip`.

By default builds are signed ad hoc for local development. Set `DISKSENSE_SIGNING_IDENTITY` to an existing Developer ID certificate for hardened-runtime signing. See [release requirements](docs/RELEASE.md) before distributing binaries.

CI builds and tests on macOS 14 and 15. Tests use disposable fixtures and injected Trash operations; they do not clean a real home directory or empty Trash. A 5,000-file fixture exercises complete indexing and a nested folder query. Local timings are evidence for that fixture only, not a competitor benchmark.

## Scope

There is no incremental/FSEvents indexing, automatic background cleanup, APFS snapshot management, or privileged system cleaner. Folder refreshes are full measurements of the selected root. Categories and related-app matching are heuristics, not guarantees that data is disposable.

See [contributing](CONTRIBUTING.md), [security](SECURITY.md), [source provenance](docs/PROVENANCE.md) and [MIT license](LICENSE).
