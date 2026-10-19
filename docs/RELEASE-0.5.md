# LintGoblin 0.5.0-beta.1

DiskSense is now **LintGoblin**: a native, open-source Mac app cleaner and disk space analyzer. “Your apps moved out. Their crumbs didn’t.” The bundle identifier and local data directory keep their original names to retain existing history and settings.

## Changes

- Applications now has a searchable app list and a dedicated connected-files workspace: grouped possible connections, per-item sizes, caution text and Reveal actions.
- Select the app bundle, its related files, or individual connections. Related data starts unselected. Normal quit requests affect only the associated app; unrelated apps may remain open. Removal rechecks whether the associated app relaunched.
- Added a separate permanent deletion method behind typed DELETE confirmation. Trash remains the default. Changing the review selection or method clears the confirmation. The engine rechecks protected paths, identity, running apps and ancestor symlinks before removal.
- Cleanup history distinguishes irreversible deletions from recoverable Trash operations, preserving older receipts.
- Expanded read-only related-file discovery to selected shared Library locations. Global launch agents, daemons and privileged helpers are reveal-only.
- Added the animated Goblin mark, original icon/banner, a real sample-data walkthrough, workflow-focused README and permissions/removal FAQ.

## Validation

74 tests in 12 suites passed locally. The optimized package passed strict local ad-hoc signature verification. Native UI checks covered connected-file selection, protected app bundles, the disabled irreversible action before confirmation, and sample-folder map/list navigation. No personal files were removed in UI checks. The recorded demo uses generated sample files, is played at 2× speed and omits macOS title-bar controls.

Automated macOS 14 and 15 results are linked from this release’s GitHub Actions check. The app deployment target remains macOS 13; comprehensive macOS 13, Intel and Apple Silicon hardware validation is still pending.

## Source beta limits

There is no signed/notarized consumer download and no privileged deletion helper. Reveal protected items in Finder to use macOS authentication where permitted. Full Disk Access does not grant root write privileges. The app never empties Trash automatically. Permanent deletion is not secure erasure and does not remove backups or APFS snapshots.

Related-file matching is heuristic and may miss connections or suggest shared data. Scan indexes are bounded; search and duplicates cover indexed entries. APFS clones and snapshots affect physical space reclaimed. See the README, FAQ and production release checklist before use.
