# ember

Steam library tooling: a 64-bit client hook plus a shared Lua backend with two
front ends (in-Steam plugin, CLI).

## Layout

| Path | What |
|---|---|
| `packages/core` | C++20 `LD_AUDIT` library — licensing, depot keys, manifest pins |
| `packages/cli` | Lua entry point (planned) |
| `packages/plugin` | Millennium plugin (planned) |
| `modules/nixos.nix` | NixOS module: wraps Steam with the audit library |
| `scripts/install.sh` | Arch / Fedora installer |
| `../ember-core` | The audit library source |

## Install

### NixOS

```nix
inputs.ember.url = "github:axioncs/ember";

modules = [ ember.nixosModules.default ];

programs.ember.enable = true;
```

`LD_AUDIT` is set by the Steam wrapper at build time. Setting
`programs.ember.enable = false` reverts to vanilla Steam.

### Arch / Fedora

```sh
./scripts/install.sh
```

The script refuses to run on NixOS and points at the module instead.

## Usage

Drop a stplug-in script into `~/.steam/steam/config/stplug-in/` and restart
Steam. Every `addappid(<id>)` in it grants ownership of that app; depot keys and
`setManifestid` pins are imported in the same pass.

```
addappid(1245620)
addappid(1245620,1,"<64 hex>")
setManifestid(1245620,"<gid>")
```

`ember import <file.lua|file.zip>` is planned (M4) and will do the same without
a restart.

## Milestones

- **M0** core builds 64-bit and loads into the client ✅
- **M1a** stplug-in importer: app ids, depot keys, manifest pins ✅
- **M1b** depot-key substitution in the CM response hook
- **M2** manifest store (downloads for builds no source publishes)
- **M3** appinfo provisioning (only if the library needs it)
- **M4** CLI, including `ember import`
- **M5** Millennium plugin, including the ProtonDB badge

## License

AGPL-3.0-only. The audit library is derived from
[AceSLS/SLSsteam](https://github.com/AceSLS/SLSsteam); see `LICENSE` in
`ember-core`.
