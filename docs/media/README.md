# Original artwork and real app recording

- `banner.png`: original 1200 × 630 repository/social banner, rendered by `scripts/MakeBrandMedia.swift` after `scripts/build-app.sh`.
- `icon.png`: the 1024 px original code-drawn icon from `scripts/MakeIcon.swift`.
- `space-map.gif`, `space-map.mp4`, `space-map.png`: captured from the actual LintGoblin 0.5 app window using generated files from `scripts/create-demo-fixture.py /tmp/LintGoblin-Demo`. No personal file paths or inventories appear. Playback is 2× real time; the top 64 physical pixels were cropped to remove macOS title-bar controls. No audio was recorded.

The recording demonstrates Space Map inspection, folder zoom, list switching and shared navigation. It is a navigation demonstration, not a scan-speed benchmark. Its sample files have arbitrary repeated contents and are not playable media or installable packages.

Do not point the fixture generator at personal folders. It refuses to overwrite a nonempty directory without its own fixture marker. App screenshots may disclose paths; inspect every capture before publishing.
