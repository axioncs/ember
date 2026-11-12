# ember

Steam library tooling: a 64-bit client hook plus a shared Lua backend with two
front ends (in-Steam plugin, CLI).

Replaces the `slsteam-moon` + `Lumen` + `luatools-moon` stack, which is 32-bit
only and no longer maintained.

## Layout

| Path | What |
|---|---|
| `packages/core` | C++20 `LD_AUDIT` library — licensing, depot keys, manifest pins |
| `modules/nixos.nix` | NixOS module: wraps Steam with the audit library |
| `../ember-core` | Fork of AceSLS/SLSsteam, branch `ember` off `dev-multiarch` |

Planned: `packages/cli` (Lua entry point), `packages/plugin` (Millennium plugin).

## Why this shape

- **64-bit.** Steam's client is `steamrt64/steam` (ELFCLASS64). The old stack
  shipped `-m32` audit libraries, which `ld.so` rejects with
  `wrong ELF class: ELFCLASS32`.
- **No installer.** `LD_AUDIT` is set by the Steam wrapper at build time; there
  is no `install.sh`, no auto-update, no guardian daemon.
- **No sidecar.** The frontend bridge is Millennium (MIT, in nixpkgs), not a
  bespoke CEF/CDP shim.

## Build

```fish
nix build .#core
```

## Milestones

- **M0** core builds 64-bit and loads into the client
- **M1** stplug-in importer, depot-key substitution, ticket stamp
- **M2** manifest store and pins
- **M3** appinfo provisioning
- **M4** CLI
- **M5** Millennium plugin
