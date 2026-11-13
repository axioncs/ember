# ember — handoff

Everything a fresh session needs. Read this before acting.

## Goal

A 64-bit Steam library hook. The earlier 32-bit approach no longer works: Steam
moved to the `steamrt64` client, which rejects `-m32` audit libraries with
`ELFCLASS32`.

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
- **Depot plan**: `src/feats/apps.cpp`. `CUserAppManager::BuildDepotDependency`
  returns an empty vector for unowned apps, so the plan is synthesised from the
  stplug-in pins, filtered by appinfo `oslist`, `language` and `baselanguages`,
  split into `depots`/`sharedDepots` by `sharedinstall`, and handed back with
  `success || synthesised`. Installs download and complete. Details and the
  round-by-round history are below.
  `BIsSubscribedApp` is also hooked (returns true for added apps) so Steam's own
  planner can build the plan where it is willing to — the log says
  `planner produced` when that happens and `synthesised` when it falls back. On
  the Nov-2025 client the planner still bails, so synthesis is the live path.

## Depot plan (solved)

Installs of added apps used to report 0 B and mount nothing. The plan layer is now
done; the sections below are the record of how, kept because the layouts and the
filter rules are the expensive part to re-derive.

After licensing was fixed, an install started but downloaded nothing. All added
games showed 0 B. `content_log.txt` said `0 mounted depots`.

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

### Plan — implemented in ember-core 0d72525

`appId` now reaches `Apps::buildDepotDependency`. When `depots->size == 0` and
`g_config.isAddedAppId(appId)`, `synthesiseDepotPlan()` rebuilds the plan from the
stplug-in pins: one `DepotInfo_t` per depot the app's own script pins to a
manifest, blacklist/override loop unchanged afterwards.

Supporting change in the importer: it now keeps the app↔depot association it
previously discarded (`Import_t::depotsByApp`, deduped, file order) plus the size
from the three-argument `setManifestid`. `StPlugin::depotPinsFor(appId)` returns
it. Depots with no manifest pin are dropped — the plan asserts a valid manifest
id and Steam denies manifest requests for unowned depots.

### Unknown 1 — DepotInfo_t / CUtlVector layout: RESOLVED from the binary

Pattern `CUserAppManager::BuildDepotDependency` resolves to `0x1079640` in the
Nov-2025 `steamrt64/steamclient.so` (single match). Read out of its own code:

```
1079ce6:  ecx = [vector+0x10]      ; m_Size
1079cf1:  shl $5, rdx              ; stride 0x20 == sizeof(DepotInfo_t)
1079d30:  eax = [vector+0x8]       ; m_nAllocationCount
1079d47:  [vector+0x10] = size+1
```

So `CUtlVector<T> = { T* base@0x0, i32 alloc@0x8, i32 growSize@0xC, i32 size@0x10 }`
— exactly what `src/sdk/CUtl.hpp` already had. Note the client's type is 0x18 bytes
(tail padding), while ember's is 0x14 because `SDK_Class` expands to
`class __attribute__((packed)) __attribute__((aligned(1)))`. Member offsets are
identical, which is the whole contract; `apps.cpp` now asserts them with
`offsetof` instead of `sizeof`.

`DepotInfo_t` is 0x20 bytes, rebuilt from the reset loop at `0x107a480`
(`movups` 0x8..0x17, `movq` 0x0, `movl` 0x18, `mov` word 0x1C, `movb` 0x1E —
0x1F never touched = padding):

| off | meaning | evidence |
|---|---|---|
| 0x00 | depotId | `cmp (%rax),%ebp` walking the vector with depot ids |
| 0x04 | appId | the app id argument, set before the append |
| 0x08 | manifestId (`m_ulManifestID`) | `cmp %rbx,0x8(%rax)`; assert string `pExistingDepotInfo->m_ulManifestID == depotInfo.m_ulManifestID` |
| 0x10 | unknown | every client-built entry leaves it 0 |
| 0x18 | unknown (u32) | from the temp the append copies |
| 0x1C,0x1D,0x1E | three bytes, separate flags | 0x1C set in one path, 0x1D set when a depot is matched, 0x1E from a predicate |

The old header claimed `size@0x10` + `lcsRequired@0x1C`, which does not survive
that evidence; `0x10` is left name-neutral and unused. ember writes only
depotId/appId/manifestId and zeroes the rest — a state the client itself builds.

Growth semantics (`CUtlMemory::Grow` at `0x1070870`): `Grow(mem, deficit)` →
`newAlloc = ComputeNewAllocation(alloc, growSize, alloc+deficit, 0x20)` (align to
a `growSize` multiple when nonzero, else geometric), written to `m_nAllocationCount`
*before* the realloc, then the caller sets `m_Size`.

### Unknown 2 — allocator: RESOLVED, use tier0 `Plat_Alloc`/`Plat_Realloc`

`CUtlMemory::Grow` allocates through `g_pMemAllocSteam`:

```
10708a1: rdx = &g_pMemAllocSteam ; rdi = [rdx] ; r10 = [rdi]   ; IMemAlloc*
10708ce: call *0x30(%r10)   ; Realloc(this, ptr, bytes, ...)  when base != 0
107094e: call *0x28(%r10)   ; Alloc(this, bytes, ...)         when base == 0
```

`steamclient.so` imports `g_pMemAllocSteam` as `UND` (GLOB_DAT at 0x32d3660), so
both modules share tier0's single `IMemAlloc`; and `Plat_Alloc`/`Plat_Realloc`/
`Plat_Free` in `libtier0_s.so` are `call *0x10`/`*0x18`/`jmp *0x20` on that same
object. Probed out of process (tier0 dlopened, `MALLOC_CHECK_=3`): `Plat_Alloc(64)`
returns a normal glibc chunk (`malloc_usable_size` = 72), and `Plat_Free`/libc
`free` accept each other's pointers. So the buffer ember hands over is freed
correctly whether the vector dies through `IMemAlloc::Free` or bare `free`.

Verified build: `nix build .#core` at ember-core `71027dd`; the `Depot plan:`
strings are in the .so, and `nix build
.#nixosConfigurations.nixos.config.programs.steam.package` in `~/nixos` resolves
`ember-core-0.1.0` (drv `a8ja3f1hnjiiax04rq9v2gvc970hlqhz`) into that closure.

### Round 1 result: plan filled, still 0 mounted depots

`Depot plan: synthesised 47 depot(s) for unowned app 1091500` logged six times, and
`content_log.txt` still said `0 mounted depots` / `0 updated, 0 moved, 0 deleted`.
The vector was filled and then thrown away. Two things were missing, both read out
of the callers of `0x1079640`:

1. **The return value is the gate.** Every call site does
   `test %al,%al; je <bail>` and the bail path frees both vectors
   (`0x107ad0d`/`0x107ad28`, `0x10b5593`/`0x10b5597`, `0x112d018`, `0x112d9de`).
   The original answers false for an app it cannot build a plan for, so a filled
   vector is discarded before anyone looks at it. The hook now returns
   `success || synthesised`.
2. **`DepotInfo_t+0x10` is the size**, summed into the install total by the caller
   (`0x107ad80: mov 0x10(%rax),%r11; add %r11,(%rbx)`), and `+0x18` is a flag that
   gates a second accumulator (the client writes 0 there itself). A plan with
   size 0 is the `0 B` in the install dialog. ember now writes the size from the
   three-argument `setManifestid`.

### Round 2 result: installs work

`Depot plan: synthesised 1 depot(s) for unowned app 1222140` plus
`handing back 1 depot(s) as success`, then `content_log.txt`:
`update started : download 0/54953473904` and
`Downloading 63178 chunks for depot 1222141`. Installs complete. The plan layer is
done.

Two things surfaced, neither a plan bug:

- **"No internet connection" on the first attempt.** The manifest blob was not
  staged yet, so Steam asked the server for a manifest request code and got
  `Access Denied` (`CDepotDownloadMgr::BYldRequestDepotManifest ... 'Access
  Denied'` → `update canceled : Failed downloading 1 manifests (No connection)`).
  After the blob is in `~/.config/ember/manifests/` the same depot downloads. Note
  `depotcache` is a staging area: Steam consumes the entry when it mounts the
  depot, so "missing from depotcache" is not a health check — the store is.
- **Depot keys are cached in `~/.local/share/Steam/config/config.vdf`** (a
  `depots` section, 56 keys here), so `GetDepotDecryptionKey` is never denied and
  `DepotKey: substituted key` never fires. The substitution layer is still
  unproven end to end; it is masked by that cache, not exercised by it.

### Round 3 result: 296 → 201 GB, still too big

The language filter worked but only removed the speech packs. Reading the pinned
manifests' file lists explains the rest — the script pins **both platforms**:

| depot | size | platform | what |
|---|---|---|---|
| 1091501 | 66.4 GB | `archive\pc\` | base content, includes `lang_en_voice.archive` |
| 1460472 | 65.2 GB | `archive\Mac\` | the same content for macOS |
| 1091502-1091509, 1460470-1460471 | 50.8 GB | pc | speech packs (PL RU FR IT DE ES JP ZH KO BRPT) |
| 1460473-1460479, 2060311-2060313 | 51.0 GB | mac | the same speech packs for macOS |
| 2138330 | 24.9 GB | pc | Phantom Liberty content |
| 2224089 | 24.5 GB | mac | Phantom Liberty content for macOS |
| 2138331-2138339 | 15.9 GB | pc | Phantom Liberty speech |
| 2224071-2224080 | 19.6 GB | mac | Phantom Liberty speech for macOS |

SteamDB confirms depot 1091501 is Windows-only and carries `lang_en_voice.archive`,
so English audio needs no speech depot at all.

### Round 4 change: platform filter + configurable language set

- **oslist**: a depot whose appinfo `oslist` names neither `windows` nor `linux`
  is dropped. That is the entire macOS half (~160 GB here). Values verified in the
  appinfo cache: `windows`, `macos`, `linux`, comma separated.
- **`DepotLanguages`** (new config key, comma separated appinfo names, empty = the
  client's language): a depot localised outside the set is dropped.
  `english,japanese` keeps English audio (in the main content depot) plus the
  Japanese voice pack.
- log: `Depot plan: app %u: %zu of %zu depot(s) localised, %zu dropped for
  language [%s], %zu dropped for platform`.

Expected for 1091500 with `english,japanese`: 66.4 + 4.9 (JP voice) + 24.9 + 1.9
(PL JP voice) + 1.8 + 0.1 ≈ **100 GB**, 8 depots.

### Round 4 result: 145 GB — the DLC's macOS half survived

Log said `10 of 47 depot(s) localised, 9 dropped for language, 12 dropped for
platform` → 26 depots kept, 158 GB of manifest size (the dialog shows ~92% of
that, which is why 318 GB read as 296 and 158 GB reads as 145).

The 26 included `2224089` (24.5 GB) and `2224071-2224080` (19.6 GB) — the macOS
half of Phantom Liberty. Cause: **a DLC's depots are described in the DLC's own
appinfo**, so `getAppData(1091500, "depots/2224089/config/oslist")` returns
nothing, "cannot tell" keeps the depot, and the platform filter never sees it.
That is also why only 10 depots were "localised": the base app's appinfo only
describes the base app's own depots.

### Round 5 change: DLC appinfo fallback + plan logging

- the depot config lookup now falls back to each app id in
  `extended/listofdlc` (verified present in the appinfo schema), so DLC depots get
  their real `oslist` and `language`.
- `Depot plan: app %u keeps <ids>` is logged once per distinct plan, because
  DEBUG is stripped from release builds and there was no way to see the list.

### Round 5 result: confirmed working

```
Depot plan: app 1091500 keeps 1091501,1091508,228988,2060310,2138330,2138335
Depot plan: app 1091500: 20 of 47 depot(s) localised, 18 dropped for language [english,japanese], 23 dropped for platform
```

6 depots, 98.2 GB of manifest size: base content (with English voice), Japanese
voice, VC redist, REDmod, Phantom Liberty content, Phantom Liberty Japanese voice.
`localised` went 10 → 20, which is the DLC fallback working: the Phantom Liberty
speech packs are now language-filtered too. 2224070 is dropped by platform (its
`oslist` is macOS-only despite the manifest carrying `archive\pc\` paths).

The user confirmed the install dialog and the download are correct.

### Round 6 change: size fallback, empty and foreign depots

Checked how the earlier 32-bit hook selected depots, expecting a language policy to
copy. It has none: a search for `language` across its feature sources returns only
`baselanguages` as metadata to skip. It never filtered depots — it provisioned
appinfo and let Steam's own planner apply `oslist`/`language`. Ember fills the
vector directly, so it has to replicate those filters itself, and already does more
than that hook did.

What the earlier hook did have, and ember lacked:

- `emptydepot.hpp`: a size-0 depot's stub manifest trips
  `Assert(!m_strName.IsEmpty())` in `contentmanifest.cpp` and SEGV-crashes the
  client while reconfiguring (documented live: Dave the Diver, depot 4394810).
- `usabledepot.hpp`: a depots map holding only metadata or virtual DLC entries has
  no installable content.

Three filters added to `synthesiseDepotPlan`, all conservative:

1. **Size fallback** — when the script's `setManifestid` carries no size, read
   `depots/<id>/manifests/public/size` from appinfo. Two-argument scripts now get an
   accurate install total instead of 0.
2. **Provably-empty depots dropped** — only when the size is *known* to be 0. An
   unknown size is kept, so this cannot regress to a 0 B plan.
3. **`depotfromapp` depots dropped** when they point at another app.

Log line extended: `... %zu dropped for platform, %zu empty, %zu provided by
another app`.

## Remaining work

1. **Depot selection.** Done: platform (`oslist`), language (`DepotLanguages`), and
   the DLC appinfo fallback. `dlcappid` is deliberately not filtered — ember cannot
   tell an owned DLC from an unowned one for an added app, and dropping Phantom
   Liberty would be wrong.
2. **Manifest coverage.** 203160 has 0 of 65 pins in the store (11 in depotcache),
   so it fails with "No connection" until its manifests are imported. User data,
   not code.
3. **Depot-key substitution end to end.** Unproven, and currently masked by the
   key cache in `config.vdf`. To exercise it: remove the depot's entry from that
   `depots` section, restart, install, and expect
   `DepotKey: substituted key for depot N (eresult was 15)`.
4. **`sharedDepots`.** Shared redist depots (228988/228989) are put in `depots`
   rather than `sharedDepots`; the caller has "already provided by another app"
   logic for the latter. Correctness nit, no known symptom.
5. **Publish ember-core.** The flake still points at
   `git+file:///home/axioncs/.local/share/ember-core?ref=ember`; switch to
   `github:axioncs/ember-core` once it is pushed.
6. **Pattern catalog maintenance.** Partly addressed: `Patterns::init()` now logs
   every signature that fails to resolve by name, at INFO, so a client update says
   exactly what moved. Re-deriving them is still manual work.
7. **AARCH64.** Patterns exist for it, never built or run.
8. ~~**`CUtlVector::resize`**~~ — fixed (see above).
9. **Docs.** README exists now; the handoff is still the deep reference.
10. **UI layer (badges, themes, settings panels).** Open, and owned by ember:
    everything Steam renders comes from the webhelper, so the layer to build is a
    CEF/CDP injector in this repo — enable the DevTools endpoint, attach over
    WebSocket, inject JS into `SharedJSContext` and the store webviews, and serve
    page calls from the CLI over `Runtime.addBinding`. No third-party framework,
    no `libXtst` proxy in the client tree.
    - (1) endpoint discovery — done: `ember ui status` reports the marker file,
      every webhelper's `--remote-debugging-port`, and whether `/json/list`
      answers. Verified on the live client: 8 webhelpers, none flagged, marker
      absent, nothing listening on 8080.
    - (2) the enable lever — open. On the SteamRT3 client the binary carries the
      `-cef-*` flags but no `cef-enable-remote-debugging` string, so the marker
      file has to be tested against a real restart before anything is built on it.
    - (3) WebSocket CDP client, (4) binding + host-side fetch (the store page's
      CSP blocks a page-side fetch), (5) the badge, then themes.
10. ~~**No tests.**~~ — done: the parser is now a pure unit
    (`src/feats/stplugin_parse.{hpp,cpp}`) with `tools/test_stplugin.cpp` covering
    every bug that shipped (raw-string terminator, three-argument `setManifestid`,
    filename-as-app-id, comments, CRLF, malformed lines, duplicate depots).
    `make test-stplugin` runs on the host; `nix build .#checks.x86_64-linux.stplugin`
    runs it in the sandbox.
11. ~~**No crash guard.**~~ — done: `~/.config/ember/.boot-in-progress` is written
    before hook placement and removed after. If it survives, the next start runs
    vanilla for one session.
12. ~~**No manifest validation.**~~ — partially: zero-byte manifests are refused.
    A real manifest parse (gid vs filename) is still open.
13. ~~**`~/.ember.log` unbounded.**~~ — done: rotated to `.ember.log.1` past 8 MiB.
14. ~~**No uninstall for the script path.**~~ — done: `install.sh --uninstall`
    removes the library, the launcher, and only a desktop entry that carries our
    `LD_AUDIT` line.
15. **No config schema version.** Deferred: the value is low while the config is
    regenerated from the template, and adding the key would warn every existing
    config once.
16. ~~**Zip path traversal**~~ — fixed: `ember import` lists entries with
    `unzip -Z1` and refuses absolute paths, `..`, and drive letters before
    extracting. Verified with a crafted archive.



## Findings worth not re-deriving

| Symptom | Cause |
|---|---|
| `wrong ELF class: ELFCLASS32` | 32-bit audit libs vs 64-bit client. Present since install day; noise for child processes only |
| `Failed to find all patterns` | Stale pattern catalog after a client update — the old stack's real death |
| `0 mounted depots` / 0 B | Empty `BuildDepotDependency` vector (see above) |
| Install plans every language pack and the macOS half | A script pins every depot the app has. Steam filters by appinfo `depots/<id>/config/oslist` and `.../language`, and a DLC's depots are described in the **DLC's** appinfo (`extended/listofdlc`), not the base app's |
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
9. **`LOG_DEBUG`/`LOG_TRACE` are compiled out in the release build** (they sit
   inside `#ifdef DEBUG`), and the nix package does not set `DEBUG`. Anything a
   test has to observe must be logged at `INFO` — `rg 'Vec Alloc'` in `.ember.log`
   returns nothing for a perfectly healthy run.

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

- The user said: **do not copy other projects' code** (including the patchset
  offered upstream for the earlier hook). Implement independently. That issue is
  useful only as a description of the problem.
- Do not tell the user to roll Steam back to the 32-bit client. They chose ember.
- **Do not publish either repo** (no `gh repo create`, no push to a public remote)
  until the user has verified everything. The flake inputs stay local paths.
- Verify before claiming. Two guesses in this project were wrong and each cost a
  build-and-click cycle.
- Terse, mechanism-first reporting; no padding.
