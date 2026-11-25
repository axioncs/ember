# Changelog

## v0.8.0 (pending)

Release scope: ember-core commits `b5986b9`, `8809a1c`, plus the CI fixes on
top of them; ember's flake, installer and CLI changes since `v0.7.9`.

### Core

- Cloud saves for added apps now deliver answers on the CM receive path instead
  of relying on the send side alone, with locally incremented change numbers and
  one `Cloud` switch. The inherited `DisableCloud` key is gone.
- Re-uploading unchanged save bytes now returns a successful PUT instead of an
  HTTP 400. A 400 on one file aborted Steam's whole upload batch, which is what
  broke Celeste's cloud sync.
- The ticket path no longer touches apps the account owns.
- Steam's remote-debugging marker resolves the client's real Steam root instead
  of a hardcoded path.

### Launch model

- `steam` / **Steam** remains the distributor's untouched client.
- `steam-ember` / **Wired Steam** is the ember-enabled launcher. The installer
  no longer patches packaged desktop entries, and an older shim install is
  restored on upgrade.

### Packaging and CI

- The release job builds the artifact from the core tag of the same name and
  refuses to publish when the artifact hash drifts from the pin.
- The installer functional test and the core test suite run on every change.
  Both had defects in their test harness: the stub `make` ignored `install.sh`'s
  `-C`, and the optional-locator test exited 2 on machines with no Steam client.
- The published artifact is pinned in `flake.nix` only after a tag has built.
  Until then the flake builds from source.

### Acceptance before tagging

Celeste (app 504230) must finish an upload with `Upload complete, result OK` in
`cloud_log.txt` and no `PUT ... rejected` line in `~/.ember.log`.
