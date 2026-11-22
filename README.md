# tama-emu-ios

## TestFlight

`.github/workflows/ios-testflight.yml` archives and uploads the iOS app. Put `*u` in a commit
subject on `main` to upload, `*b` to archive only, or run it by hand from Actions. Signing uses
Xcode cloud signing and never revokes certificates.

The workflow finds the project itself (the first `*.xcodeproj`, or an XcodeGen `project.yml`,
within three folders of the root). For a new app, create it once in App Store Connect
(Apps → + → New App) with the project's bundle ID; the first upload run prints it if it's missing.

## Theme

`.claude/skills/vfd-theme/SKILL.md` is the "Amber VFD" dot-matrix theme. Ask for "vfd" to use it.
