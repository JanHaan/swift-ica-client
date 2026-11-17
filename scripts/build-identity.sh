# Sourced by bundle.sh and bundle-helper.sh: sets $version (ICA_VERSION or the VERSION file), $build
# (git commit count, 1 outside git) and $commit_xml (the ICAGitCommit plist line, empty without git).
# Works in any git checkout, including the scrubbed public tree.
version="${ICA_VERSION:-$(tr -d ' \n\r' < "$root/VERSION" 2>/dev/null || true)}"
version="${version:-0.1}"
build=1
commit_xml=""
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1 && git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
    commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
    if [ -n "$commit" ]; then
        [ -z "$(git -C "$root" status --porcelain 2>/dev/null | grep -v "\.DS_Store$")" ] || commit="$commit-dirty"
        commit_xml="<key>ICAGitCommit</key><string>$commit</string>"
    fi
fi
