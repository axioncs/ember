# Arch package

`ember-git` builds both repositories from source and installs:

| Path | What |
|---|---|
| `/usr/lib/ember/ember-core.so` | The library |
| `/usr/bin/ember` | The CLI |
| `/usr/bin/steam-ember` | `steam`, launched with the library attached |

`steam-ember` exists because the library has to be attached at launch. Stock
`steam` is left alone, so the package is safe to install alongside it.

## Build locally

```sh
cd packaging/aur
makepkg -si
```

## Publish to the AUR

The AUR needs its own git repository per package:

```sh
git clone ssh://aur@aur.archlinux.org/ember-git.git
cp PKGBUILD .SRCINFO ../ember-git/
cd ../ember-git && git add . && git commit -m "ember-git $(date -u +%Y-%m-%d)" && git push
```

Regenerate `.SRCINFO` after every PKGBUILD change:

```sh
makepkg --printsrcinfo > .SRCINFO
```

## Status

Untested. It was written on NixOS, where `makepkg` does not exist. The build
commands are exactly what `scripts/install.sh` runs, which is verified to work on
this source tree, so the risk is in packaging details (deps, install paths) rather
than in the build.
