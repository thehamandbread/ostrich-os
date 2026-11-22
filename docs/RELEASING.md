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

## Owner steps for the rename (0.6.0, ships alone)

Order matters. Do not skip ahead; the live-machine upgrade is the last step.

1. **Dev VM path.** Stop the dev VM (`tests/vm/vm.sh stop`), then
   `mkdir -p ~/.local/share/ostrich-os && mv ~/.local/share/ubuntu-ostrich/vm ~/.local/share/ostrich-os/vm`.
   The test scripts now default to the new path. Do this before upgrading the dev machine.
2. **Merge** the `rename-ostrich-os` branch (CI green, `tests/rename.bats` and `tests/appid-lint.sh` pass).
3. **Rename the repo:** GitHub → Settings → rename `ubuntu-ostrich` to `ostrich-os`. GitHub then
   redirects the old name (web, git, API, raw files, release downloads). **Never create a repo named
   `ubuntu-ostrich` again:** it would take over the redirect and strand every installed 0.5.0.
4. **Tag `v0.6.0`** and push the tag (the release workflow publishes the tools, zips and `SHA256SUMS`).
5. **Check the URLs and record the output here** (each chain should end in `200 OK`):

   ```bash
   wget -S --spider https://raw.githubusercontent.com/thehamandbread/ubuntu-ostrich/v0.5.0/install.sh 2>&1 | grep -E 'HTTP/|Location'
   wget -S --spider https://raw.githubusercontent.com/thehamandbread/ostrich-os/v0.6.0/install.sh 2>&1 | grep -E 'HTTP/|Location'
   wget -S --spider https://github.com/thehamandbread/ostrich-os/releases/download/v0.6.0/SHA256SUMS 2>&1 | grep -E 'HTTP/|Location'
   ```

   Recorded: _(not run yet: needs the rename and the tag)_
6. **If the old raw URL does not end in 200**, put the new one-liner
   (`wget -qO- https://raw.githubusercontent.com/thehamandbread/ostrich-os/main/install.sh | bash`)
   at the top of the README and on the 0.5.x release page.
7. **Live-machine upgrade** comes only after all of the above pass, and after `tests/vm/rename-test.sh`
   (the 0.5.0 → 0.6.0 proof in a lab VM) has passed; see `docs/FEATURES.md` REN-1…REN-6.

What the upgrade does to a 0.5.0 machine is in `docs/plans/01-rename.md`; the user-facing note is in
`docs/INSTALLING.md`.

