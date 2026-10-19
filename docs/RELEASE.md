# Release checklist

## Required before a production binary release

- Passing `./scripts/test.sh` and release package signature verification.
- Passing GitHub macOS 14/15 CI; test the app itself on every advertised supported OS and Apple Silicon/Intel hardware before claiming coverage.
- Manual verification of cross-folder map/list navigation, cached returns, cancellation, disconnected external drives, missing permissions and stale saved results.
- Developer ID Application signing with hardened runtime and notarization. Local ad-hoc builds are development artifacts and do not prove Gatekeeper acceptance or stable Full Disk Access approval.
- Review known limitations in README, include hashes and accurate version notes, and never package scan databases or user reports.

## Signed and notarized package

With an existing Developer ID certificate in Keychain:

```sh
DISKSENSE_SIGNING_IDENTITY='Developer ID Application: YOUR IDENTITY' ./scripts/build-app.sh
xcrun notarytool submit .build/Distribution/LintGoblin-0.5.1.zip --keychain-profile DISKSENSE_NOTARY --wait
xcrun stapler staple .build/Distribution/LintGoblin.app
xcrun stapler validate .build/Distribution/LintGoblin.app
spctl --assess --type execute --verbose .build/Distribution/LintGoblin.app
ditto -c -k --sequesterRsrc --keepParent .build/Distribution/LintGoblin.app .build/Distribution/LintGoblin-0.5.1.zip
shasum -a 256 .build/Distribution/LintGoblin-0.5.1.zip
```

The Keychain profile must already be configured by the developer; no passwords or signing keys belong in this repository. Submit/staple/assessment must actually succeed before describing a build as notarized. Never tell users to disable Gatekeeper or other system protections.

## Current verification

Local regression and UI results are recorded in release notes. Source publication and CI artifacts do not mean the production checklist above has been completed. Keep beta status until the remaining external validation gates are satisfied.
