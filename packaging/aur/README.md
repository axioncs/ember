# Arch package

`ember-git` builds both repositories from source and installs:

| Path | What |
|---|---|
| `/usr/lib/ember/ember-core.so` | The library |
| `/usr/bin/ember` | The CLI |
| `/usr/bin/steam-ember` | `steam`, launched with the library attached |

The library has to be attached at launch, so plain `steam` does nothing on its own.
Stock `steam` is left untouched and the package is safe alongside it — `steam-ember`
is opt-in, and the post-install message explains how to wire up your normal Steam
icon instead.

## How the AUR works

The AUR is a **git repository per package**, not a binary host. You push a
`PKGBUILD` and `.SRCINFO`; users run `makepkg` and it builds locally. There is no
upload step and no review before publication, which is why the rules are strict
about what a PKGBUILD may do.

What you need:

1. **An AUR account** — <https://aur.archlinux.org/register>.
2. **Your SSH public key registered** under *My Account → SSH Public Key*. Without
   it, `git push` to `aur@aur.archlinux.org` fails with
   `Permission denied (publickey)` — which is the current state.
3. Nothing else. The key is the only credential.

## First publish

```sh
# 1. Clone the (empty) package repository. This is how a new package is created.
git clone ssh://aur@aur.archlinux.org/ember-git.git
cd ember-git

# 2. Copy the packaging files in.
cp ~/.local/share/ember/packaging/aur/PKGBUILD .
cp ~/.local/share/ember/packaging/aur/.SRCINFO .
cp ~/.local/share/ember/packaging/aur/ember-git.install .

# 3. Commit and push. The push creates the package.
git add PKGBUILD .SRCINFO ember-git.install
git commit -m "ember-git v0.1.0: initial upload"
git push
```

It appears at <https://aur.archlinux.org/packages/ember-git> within a minute.

## Every update after that

One commit per version bump, and `.SRCINFO` must match the `PKGBUILD` exactly.

```sh
cd ember-git
cp ~/.local/share/ember/packaging/aur/PKGBUILD .
cp ~/.local/share/ember/packaging/aur/ember-git.install .
makepkg --printsrcinfo > .SRCINFO      # regenerate, never hand-edit
git add PKGBUILD .SRCINFO ember-git.install
git commit -m "upgpkg: ember-git $(date -u +%Y.%m.%d)"
git push
```

`.SRCINFO` is generated. A hand-edited one that disagrees with the `PKGBUILD` gets
rejected by the AUR's own checks.

## Before you push: build it

```sh
cd packaging/aur
makepkg -si        # builds, installs, prints the post-install message
namcap PKGBUILD    # optional dependency and packaging lint
```

`makepkg` must not run as root. With `devtools`, build in a clean chroot:

```sh
extra-x86_64-build
```

## What the AUR will not accept

- **Binaries.** It builds from `source=()`, which is why the library is compiled
  here. A prebuilt `.so` would also be wrong: it has to match the linker and
  libcurl it runs against.
- **A non-deterministic `pkgver`.** This is a `-git` package, so `pkgver()` derives
  from the history; that is expected.
- **Downloads at build time.** Everything is fetched through `source`.
- **`.SRCINFO` drift.** Covered above.
- **No licence file.** The package installs the AGPL-3.0 text into
  `/usr/share/licenses/ember-git/`.

## For users, once published

```sh
yay -S ember-git
steam-ember
ember doctor
```

With an AUR package, `scripts/install.sh` is no longer needed on Arch; it remains
the fallback for other distros.

## Status

`bash -n` passes, but this has **never been built with `makepkg`** — it was written
on NixOS, which has none. The build commands are the ones `scripts/install.sh` runs,
so the risk is in packaging details (deps, paths) rather than in the build. Run
`makepkg -si` on an Arch box before the first push.
