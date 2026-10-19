# LintGoblin FAQ

## What is LintGoblin?

LintGoblin is a free, MIT-licensed Mac disk space analyzer and app cleanup utility written in SwiftUI and AppKit. It combines a visual Space Map, app-related file review, exact duplicate checking, cleanup plans and Trash history. It was called DiskSense before version 0.5.

## Can I see an app’s connected folders without deleting it?

Yes. Select the app in Applications and use Reveal beside its bundle or any suggested connection. Select related files separately from the app bundle. Nothing is selected initially in the connected-files workspace. No deletion happens until a separate review is confirmed.

## Does it find every leftover from an app?

No. It examines accessible, allowlisted user and shared Library locations and matches immediate entries by bundle identifier or whole app name. It does not infer all sandbox entitlements, every vendor helper, or every custom storage location. A match is a review suggestion; shared containers and personal support data need care. Launch daemons, global launch agents and privileged helper entries are reveal-only.

## Can it permanently delete files?

Yes, for allowed paths that the current user can remove. Trash is the default. Permanent deletion requires selecting that mode, reviewing the selected paths and typing DELETE. Changing the selection or removal method clears that confirmation. The engine rechecks path safety, running apps and the reviewed file identity. Permanently deleted files cannot be restored by LintGoblin. This is ordinary filesystem removal, not secure erasure; backups and APFS snapshots may retain copies.

## Does it ask for an administrator password?

This source beta has no privileged helper. Reveal an administrator-protected item in Finder, inspect it there and use Finder’s own authentication where macOS permits removal. LintGoblin does not collect your password, run hidden sudo commands, stop system services or bypass SIP. Proper in-app privileged removal remains future work and needs a narrowly scoped, signed and audited helper.

## Why does it still show a permission message after Full Disk Access is enabled?

macOS permissions are tied to the app identity. Replacing a locally ad-hoc-signed build can invalidate an approval even while its switch remains on. In Privacy & Security → Full Disk Access, re-enable the current build and relaunch it, then Recheck. Full Disk Access permits reading protected data; it does not grant administrator write privileges or bypass System Integrity Protection. Accessible folders still scan without it.

## Do I need to close all my apps?

No. When reviewing an app’s connected files, only the associated app must quit. Ask app to quit sends a normal quit request, allowing the app to handle unsaved work. It does not force quit. A running associated app is checked again at removal time. Shared data can still affect other apps, so review ownership yourself.

## Why doesn’t deleting a large file free the same amount of space?

Allocated file sizes are estimates of storage associated with paths. APFS clones, snapshots, open file handles and purgeable storage affect reclaimed capacity. Items moved to Trash still use space until Trash is emptied in Finder. LintGoblin reports removals and measured sizes separately from volume capacity.

## Can I scan another folder or an external drive?

Yes. Choose folder or volume works from the sidebar and Space Map. Map and list share navigation. Cached results show their scan time; refresh when you want current measurements. Scans stay on the starting filesystem and report unreadable paths. A full folder scan can take time; cached navigation avoids repeating it unnecessarily.

## Are duplicates safe to delete?

Exact byte matches are verified with streaming SHA-256 for eligible indexed local files of at least 1 MiB. Symlinks, hard links, cloud placeholders and managed locations are excluded. An unselected copy and all selected identities are checked again before confirmation. This establishes matching contents at verification time, not that deleting a copy will preserve every application workflow.

## Is my disk data uploaded? Is there an AI service inside the app?

No. The app has no accounts, telemetry, uploads or runtime network features. Analysis and SHA-256 checks run locally. Reports are exported only when you choose to save them. GitHub issue reports and manually uploaded reports are separate actions you control.

## Is there a signed download or Homebrew cask?

Not yet. The public release is a source beta. Build locally using the README. CI artifacts and locally ad-hoc-signed packages are development builds, not notarized consumer installers. Do not disable Gatekeeper or other protections to run an unverified download.

## How does it compare with AppCleaner and commercial disk analyzers?

The aim is to combine an app-connected-file inspection workflow with disk visualization and explicit cleanup review. It is an independent project, not affiliated with those apps. There are no published controlled speed benchmarks or claims that it finds more leftovers. Choose it if you want inspectable MIT source, local analysis and combined workflows, and are comfortable with beta limitations.
