# ember — handoff

Everything a fresh session needs. Read this before acting.

## Goal

A maintained replacement for the `slsteam-moon` + `Lumen` + `luatools-moon` stack,
which broke when Steam moved to the 64-bit `steamrt64` client (its audit libs are
`-m32` and get rejected with `ELFCLASS32`).

Target: 64-bit core, distro-agnostic (Arch/Fedora via script, NixOS via module),
no installer daemons, no sidecar. Named **ember**.

## Layout

| Path | What |
|---|---|
| `~/.local/share/ember-core` | C++20 audit library. Fork of `AceSLS/SLSsteam`, branch `ember` off `dev-multiarch` |
| `~/.local/share/ember` | flake: `packages.core`, `packages.cli`, `packages.steam`, `nixosModules.default`, `scripts/install.sh` |
| `~/nixos` | consumer: `ember.url = "path:/home/axioncs/.local/share/ember"`, `ember.nixosModules.default`, `programs.ember.enable = true` |

## Build / test loop

This is how the user wants to work: agent edits and commits, user rebuilds and tests.

```fish
# after editing ember-core
cd ~/.local/share/ember-core && git commit -am "..."
cd ~/.local/share/ember && nix flake update ember-core && nix build .#core
cd ~/nixos && nix flake update ember && nix build .#nixosConfigurations.nixos.config.programs.steam.package
# user then:
nh os switch ~/nixos
# restart Steam, report back
```

`nix build .#steam` in `~/.local/share/ember` produces a wrapped Steam for testing
**without** a system rebuild. Use it: launching `/nix/store/.../bin/steam` directly
bypasses the deployed system and is faster to iterate.

## Verified working

- **Injection**: `programs.steam.package = pkgs.steam.override { extraEnv.LD_AUDIT = ...; }`.
  `extraEnv` lands in the FHS `/etc/profile`, which the container init sources.
  No wrapper script, no patched files.
- **stplug-in importer**: `src/feats/stplugin.cpp`. Parses `addappid(id)`,
  `addappid(depot,1,"hex")`, `setmanifestid(depot,"gid"[,size])` from
  `~/.steam/steam/config/stplug-in/*.lua`. Currently 46 app ids / 128 depot keys /
  123 pins.
- **Hot reload**: the stplug-in directory is added to the inotify watcher;
  `IN_DELETE` included. Dropping/removing a `.lua` reloads without a restart.
- **Ticket stamp**: `src/feats/ticket.cpp`. Denied `GetAppOwnershipTicketResponse`
  for an added app gets `eresult=OK` re-serialized (ticket bytes untouched).
- **Depot-key substitution**: `src/feats/depotkey.cpp`, called from
  `hkCMInterface_RecvPkt`. Rewrites denied `GetDepotDecryptionKeyResponse`
  (EMsg 5439) with the imported key. **Not yet proven end to end.**
- **Manifest store**: `src/feats/manifeststore.cpp` copies
  `~/.config/ember/manifests/<depot>_<gid>.manifest` into
  `~/.local/share/Steam/depotcache` on every config load.
- **CLI**: `packages/cli` (Lua 5.4). `ember import <file.lua|file.zip>`, `ember list`,
  `ember status`. Installed by the module into `environment.systemPackages`.
- **Ownership SteamID**: `hkClientUser_GetSteamId` ignores the anonymous sentinel.

## Current blocker: installs report 0 B

After licensing was fixed, an install starts but downloads nothing. All added games
show 0 B. `content_log.txt` says `0 mounted depots`.

Cause: `CUserAppManager::BuildDepotDependency` returns an **empty** depot vector for
apps the account does not own. Upstream's `Apps::buildDepotDependency` only iterates
existing entries, so an empty vector stays empty and Steam computes a zero-byte
install.

Hook point already exists in `src/hooks.cpp`:

```cpp
static bool hkUserAppManager_BuildDepotDependency(
    IClientAppManager*, AppId_t appId, void*, CUtlVector<DepotInfo_t>* depots,
    CUtlVector<DepotInfo_t>* sharedDepots, void*, uint32_t*, bool*)
{ ... Apps::buildDepotDependency(depots, sharedDepots); ... }
```

`appId` is available but not passed to `Apps::buildDepotDependency`.

### Plan (own implementation, do not copy other projects)

1. Pass `appId` into `Apps::buildDepotDependency`.
2. If `depots->size == 0` and `g_config.isAddedAppId(appId)`, synthesise entries
   from data already imported: for each pin of that app, one `DepotInfo_t` with
   `appId`, `depotId`, `manifestId`.
3. Grow the `CUtlVector` safely — Steam frees it later, so the memory must come
   from a compatible allocator.

### Unknowns to resolve first

- `DepotInfo_t` layout and `CUtlVector<T>` / `CUtlMemory<T>` layout. The types are
  used in `hooks.hpp` but their definitions were not yet located (`rg 'DepotInfo_t'`).
- Allocator: `steamclient.so` exports **no** `Plat_*` or `CUtlMemory*` symbols
  (`nm -D` checked). Valve's `CUtlMemory` on Linux uses libc `realloc`/`free`, so
  `malloc`+copy or `realloc` may work, but this is unverified. A crash here is a
  hard crash in the client, so test on the smallest surface possible.

## Findings worth not re-deriving

| Symptom | Cause |
|---|---|
| `wrong ELF class: ELFCLASS32` | 32-bit audit libs vs 64-bit client. Present since install day; noise for child processes only |
| `Failed to find all patterns` | Stale pattern catalog after a client update — the old stack's real death |
| `0 mounted depots` / 0 B | Empty `BuildDepotDependency` vector (see above) |
| `No licenses` on install | The app id was missing from `addedAppIds`. A script named `1091500.lua` had **no bare `addappid(1091500)`** — only a depot-key line. Fix: the filename is an app id |
| Stealth ignore of everything | `CSteamId::isSet()` is `accountId() != 0`; `GetSteamID` returns the anonymous sentinel (`76561197960265728`) before login |
| No "loaded" toast | `NotifyInit` gates it; it is `yes` again and now logs app id count |

## Pitfalls that cost real time

1. **Raw string literals**: `R"(...)"` terminates early if the body contains `)"`.
   This broke the first parser. Hand-parse instead of using `<regex>`.
2. **`setManifestid` three-argument form** (`setmanifestid(depot,"gid",size)`) is used
   by whole archives (Hubcap). Two-argument-only parsing silently drops every pin.
3. **Trailing comments** (`addappid(2441600) -- name`) are common; strip before parsing.
4. **Script filename is the app id** — generators may omit the bare line.
5. **`pkill -f 'pattern'` matches its own command line.** Use the bracket trick:
   `pkill -f 'steamrt64/stea[m]'`.
6. **`steam steam://install/<id>` does not reach a running client** from the shell.
   Tried four ways. The user must click Install.
7. **The FHS profile overrides `LD_AUDIT`** from your shell, so testing a new core
   requires rebuilding the steam package (`nix build .#steam`), not just an env var.
8. **`os.execute` in Lua 5.4 returns `true`/`nil`**, not an exit status. And `gsub`
   returns two values — wrap in parentheses before `table.insert`.

## Useful probes

```fish
# is the core in the client, and where from
p=$(pgrep -f 'steamrt64/stea[m]' | head -1); grep -o '/nix/store/[a-z0-9]*-ember-core' /proc/$p/maps | head -1

# what the core did this session
rg -n 'VFTables resolved|Patterns resolved|Hooks placed|Captured SteamID|stplug-in:|Ticket: stamped|DepotKey|ManifestStore|ember loaded' ~/.ember.log

# why an install did nothing
tail -20 ~/.local/share/Steam/logs/content_log.txt

# dump Steam's interface map (hookable VFT methods by name) into the log
# set DumpClientInterfaces: yes in ~/.config/ember/config.yaml, restart, then:
awk '/^14IClientUserMap$/,/^};$/' ~/.ember.log
```

## Paths

| Thing | Where |
|---|---|
| config | `~/.config/ember/config.yaml` (generated from `res/config.yaml`) |
| log | `~/.ember.log` |
| manifest store | `~/.config/ember/manifests/` |
| stplug-in scripts | `~/.steam/steam/config/stplug-in/` |
| Steam depot cache | `~/.local/share/Steam/depotcache/` |

## Standing constraints

- The user said: **do not copy other projects' code** (slsteam-moon, the patchset
  offered in swwayps/slsteam-moon#9). Implement independently. That issue is useful
  only as a description of the problem.
- Do not tell the user to roll Steam back to the 32-bit client. They chose ember.
- Verify before claiming. Two guesses in this project were wrong and each cost a
  build-and-click cycle.
- Terse, mechanism-first reporting; no padding.
