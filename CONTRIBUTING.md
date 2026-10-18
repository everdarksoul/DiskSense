# Contributing

Use Swift 6 and macOS 14 or newer for tests (the app targets macOS 13+). Run `./scripts/test.sh`, then `./scripts/build-app.sh`.

Keep changes focused. Cleanup changes need tests for protected paths, stale identities, and failed operations. Navigation changes need cancellation and stale-callback coverage. Use disposable fixtures; never write tests that clean a real home folder or empty Trash.

Before submitting a PR, describe the user-visible change, validation, and remaining limitations. Do not commit generated builds, scan indexes, user paths, signing credentials, or reports. New source contributions are licensed under MIT.
