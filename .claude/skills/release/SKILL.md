---
name: release
description: Build, publish and install a new Flipkey release. Use when the user says "release", "create release", "ship it", "new version", or "commit push release install".
---

# Release Flipkey

A release is a git tag `vX.Y` plus a GitHub release with `Flipkey-X.Y.dmg` and `Flipkey-X.Y.zip` attached.
Versions go up by 0.1: after `v0.7` comes `v0.8`.

## Steps

1. **Pick the version.** Run `gh release list --limit 1` and add 0.1 to the latest tag.

2. **Commit and push** the pending changes on `main`:
   ```bash
   git add -A && git commit -m "<what changed, in plain words>" && git push
   ```

3. **Build.** This runs the self-test first and stops if it fails:
   ```bash
   ./build.sh X.Y    # makes build/Flipkey.app, build/Flipkey-X.Y.zip and build/Flipkey-X.Y.dmg
   ```

4. **Publish the release** with user-facing notes, one line per change, in the style of earlier releases (`gh release view <previous tag>`):
   ```bash
   gh release create vX.Y build/Flipkey-X.Y.dmg build/Flipkey-X.Y.zip --title "Flipkey X.Y" --notes "- <change>"
   ```

5. **Install on this Mac:**
   ```bash
   pkill -x Flipkey; rm -rf /Applications/Flipkey.app
   ditto build/Flipkey.app /Applications/Flipkey.app && open /Applications/Flipkey.app
   ```

## Gotchas

- Always sign with the same "Flipkey Dev" certificate. The Accessibility grant is tied to it, so an ad-hoc or new certificate silently breaks Flipkey. Before building, run `security find-identity -p codesigning | grep "Flipkey Dev"`. If it is missing, re-import the backup with `security import ~/Documents/Certificates/FlipkeyDev.p12 -k ~/Library/Keychains/login.keychain-db -P flipkey -T /usr/bin/codesign`. Never create a new certificate.
- After installing, check `codesign -dvv /Applications/Flipkey.app 2>&1 | grep Authority` (two v's, one v doesn't print it). It must say `Authority=Flipkey Dev`.
- The DMG step needs `create-dmg` (`brew install create-dmg`). It arranges the window through Finder, so a Finder window opens and closes during the build; that is normal.
- Never commit `build/`; it is in `.gitignore`.
