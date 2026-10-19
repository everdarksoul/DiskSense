# LintGoblin 0.5.1-beta.1

Fixes incomplete whole-disk indexing caused by the former 150,000-entry / 32 MiB path-text limits.

- The catalog stores each parent directory path once and references it with integer IDs. File entries retain a basename and metadata instead of repeating full paths and long scan identifiers in every index.
- Live scans have no file-count or path-text cutoff. Older scan history is evicted to meet the soft storage budget; the newest completed index is never trimmed.
- Folder queries return all indexed children. Search still displays up to 200 matches, but considers the entire readable index; duplicate candidates are not limited by that display cap.
- The upgrade preserves cleanup receipts and inventory, remembers the most recently scanned v4 root, and rebuilds its index once. Old index files are retired only after their receipts are copied successfully.
- The scanner excludes its own growing database through both ordinary and startup-data-volume paths.
- Incomplete saved results retain an explicit warning and offer Rebuild index. Permission failures remain visible.

Validation includes a 200,005-entry long-path catalog fixture, verifying late-file search, full folder results, duplicate candidates, persistence and retention. That fixture produced an approximately 24 MiB complete index locally; it is not a whole-disk performance benchmark. Tests also cover preserving v4 cleanup history and retaining the current scan under a deliberately exceeded history budget.

All 78 regression tests pass locally, and the optimized package passes strict local signature verification. A real startup-disk scan completed beyond one million indexed entries without truncation; unreadable locations are reported separately.

This remains a source beta. Developer ID notarization and an in-app privileged deletion helper are still pending. Full Disk Access and administrator write privileges are separate permissions.
