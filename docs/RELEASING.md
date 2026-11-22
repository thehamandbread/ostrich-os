# Releasing

A tag `vX.Y.Z` builds and publishes the tools and extension zips (`.github/workflows/release.yml`).
It refuses to publish unless CI passed on that commit. CI can't run the VM tests, so before tagging:

1. `VERSION` and `tools/Cargo.toml` say the new version (`cargo update --workspace --offline` in `tools/`).
2. `tests/vm/build-tools.sh --check` (fmt, clippy, tests, the release build and its `.tools-stamp`).
3. In the test VM, on that build:
   - `tests/vm/e2e.sh --pipe --from pre --uninstall`, twice: once as is, and once after
     `ostrich theme scheme apply forest` with `ostrich uninstall --keep-new-settings`;
   - `tests/vm/ext-test.sh` for every extension, `drawer-test.sh`, `a11y-test.sh`, `polkit-test.sh`,
     `dconf-test.sh`, `store-test.sh`, `motion-test.sh`, `nowplaying-test.sh`.
4. `bats tests/`, `tests/js-test.sh`, `tests/lint-js.sh`, shellcheck and shfmt (as in CLAUDE.md).
5. Tag and push the tag. Then install the release once from the one-line command in the README.
6. Check the update path on a machine with the previous release: the Store's Updates tab lists
   "Ostrich OS" with the new tag (the Store reads GitHub's latest release and compares it with
   its own version), and its Update button runs `REPO_REF=<tag> ostrich update` in a terminal.
   `ostrich update` with no tag fetches the latest release (`install.sh` `resolve_ref`), not `main`.
