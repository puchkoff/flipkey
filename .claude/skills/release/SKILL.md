---
name: release
description: Build, publish and install a new Flipkey release. Use when the user says "release", "create release", "ship it", "new version", or "commit push release install".
---

# Release Flipkey

A release is a git tag `vX.Y` plus a GitHub release with `Flipkey-X.Y.zip` attached.
Versions go up by 0.1: after `v0.7` comes `v0.8`.

## Steps

1. **Pick the version.** Run `gh release list --limit 1` and add 0.1 to the latest tag.

2. **Commit and push** the pending changes on `main`:
   ```bash
   git add -A && git commit -m "<what changed, in plain words>" && git push
   ```

3. **Build.** This runs the self-test first and stops if it fails:
   ```bash
   ./build.sh X.Y    # makes build/Flipkey.app and build/Flipkey-X.Y.zip
   ```

4. **Publish the release** with user-facing notes, one line per change, in the style of earlier releases (`gh release view <previous tag>`):
   ```bash
   gh release create vX.Y build/Flipkey-X.Y.zip --title "Flipkey X.Y" --notes "- <change>"
   ```

5. **Install on this Mac:**
   ```bash
   pkill -x Flipkey; rm -rf /Applications/Flipkey.app
   ditto build/Flipkey.app /Applications/Flipkey.app && open /Applications/Flipkey.app
   ```

## Gotchas

- The Accessibility grant survives a reinstall only if the build was signed with the "Flipkey Dev" certificate. `build.sh` prints nothing about it, so check with `codesign -dv /Applications/Flipkey.app 2>&1 | grep Authority`. If it says ad-hoc, tell the user to re-allow Flipkey in System Settings > Privacy & Security > Accessibility.
- Never commit `build/`; it is in `.gitignore`.
