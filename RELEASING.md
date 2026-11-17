# Releasing ICAViewer

A checklist for a release. Run the steps in order; stop at the first failure.

## 1. Prepare

- [ ] Everything for the release is committed on the private repository's main branch (the publish tool clones committed state only).
- [ ] `VERSION` holds the new version. README.md and FEATURES.md describe what this version does.
- [ ] `swift build` and `swift test` pass.

## 2. Rebuild the user manual

The manual (`manual/`) and its screenshots are regenerated for every release, before the disk image is built.

```sh
scripts/bundle.sh                       # the app the screenshots are taken from
scripts/manual/build.sh --pdf           # screenshots in the macOS test VM, checks, PDF
```

- [ ] The build ends with `OK (version <version>)`. It runs `scripts/manual/shots.sh` in the macOS test VM (never on your own screen), copies the images to `manual/images/`, and checks that every referenced image exists, every image file is referenced, the images are under 15 MB, no forbidden word appears in a screenshot (OCR) or in the manual text, and the publish audit's pattern list finds nothing in `manual/`.
- [ ] Look at the new screenshots (`manual/images/`), especially anything the UI changed: no password, no real company name, host, user or app; only the lab (`icalab.test`, `labuser3`, Notepad, WordPad, Paint, File Explorer).
- [ ] Read the chapters that touch changed behavior and correct the text. The screenshots update by themselves; the words do not.
- [ ] `manual/ICAViewer-Manual-<version>.pdf` exists (needs `brew install pandoc` and Google Chrome). Do not commit the PDF; it is a release asset.
- [ ] Commit `manual/` (Markdown and images).

## 3. Publish audit and tests

Run the publish tool (kept outside this repository) into a new directory:

```sh
../tools/ica-publish/publish.sh ../ica-public-<version-without-dots>
```

- [ ] `audit hits: 0` and `private paths in history: 0`.
- [ ] The tests pass in the scrubbed tree (the tool runs them).
- [ ] The scrubbed tree contains `manual/` and `RELEASING.md`, and nothing from `docs/`, `notes/` or `DECISIONS.md`.

## 4. Disk image

```sh
ICA_SIGN=developer-id ICA_NOTARY_PROFILE=<notarytool keychain profile> scripts/make-dmg.sh
```

Run it in the scrubbed tree so the shipped build identity matches the public history.

- [ ] The DMG is signed with the Developer ID, notarized and stapled (`xcrun stapler validate`, `spctl -a -vv`).
- [ ] Universal binary (`lipo -archs`), the SHA-256 file next to the DMG.
- [ ] The About panel shows the right version, build and commit, and a clean tree.

## 5. Push and release (only on the maintainer's go)

- [ ] Fast-forward push of the scrubbed tree to the public repository. Never force-push.
- [ ] Create the GitHub release for the tag with release notes, and attach:
  - `swift-ica-client-<version>.dmg` and its SHA-256,
  - `ICAViewer-Manual-<version>.pdf`.

  ```sh
  gh release create v<version> .build/dist/swift-ica-client-<version>.dmg \
      .build/dist/swift-ica-client-<version>.dmg.sha256 manual/ICAViewer-Manual-<version>.pdf \
      --title "ICAViewer <version>" --notes-file <notes>
  ```
- [ ] Download the asset from GitHub and compare its SHA-256 with the file.
- [ ] Record the release (commits, hashes, results) in the private decision log.

## Notes

- The manual's screenshots need the macOS test VM, the lab, and `.session/lab-user3.env` (`scripts/macvm/labuser.sh 3`). See `scripts/macvm/README.md`.
- If the build reports a missing screen, the UI changed under the script: look at `/tmp/icashot/macvm/<run>/` (`results.txt`, `ax-*.txt`, the screenshots) and adapt `scripts/manual/shots.sh`.
