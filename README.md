# ember

Steam library tooling for Linux. It lets Steam install and play games your account
does not own, driven by plain script files you drop in a folder.

Works on the current 64-bit Steam client, needs no background service, and does
not modify any file inside your Steam installation.

## What it does

- **Unlocks** the games listed in stplug-in scripts.
- **Builds the install plan** Steam refuses to build for apps you don't own, so
  the install dialog shows the real size and the download actually starts.
- **Stages manifests** from a local store, because Valve denies manifest requests
  for unowned depots.
- **Filters by your setup**: only your platform, only languages the game ships,
  only the language your client uses.
- **Gives you a CLI** for importing, removing, inspecting and diagnosing.

## Requirements

- Linux, x86_64, with Steam installed and logged in.
- Either NixOS, or Arch / Fedora / a derivative of them.

## Install

### NixOS

```nix
{
  inputs.ember.url = "github:axioncs/ember";

  # add ember.nixosModules.default to your modules list, then:
  programs.ember.enable = true;
}
```

Rebuild. Steam behaves exactly as before, now with ember attached. Setting
`programs.ember.enable = false` and rebuilding returns you to stock Steam.

### Arch and Fedora

```sh
curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh
```

The script downloads the release artifact for the latest tag — built in a
`debian:bookworm` container, so the library needs nothing newer than glibc 2.36 —
verifies its published SHA-256, and installs the `ember` CLI and a `steam-ember`
launcher into the user prefix (`~/.local`). If there is no artifact for your tag
it builds from source instead, installing the build dependencies only then;
`--from-source` forces that.

Flags go after `sh -s --`, otherwise `sh` swallows them:

```sh
# also point the Steam desktop entry at ember
curl -fsSL ... | sh -s -- --desktop

# build here instead of downloading the release
curl -fsSL ... | sh -s -- --from-source

# remove everything the script installed
curl -fsSL ... | sh -s -- --uninstall
```

No clone needed — the script fetches the sources itself. Set `EMBER_SRC` if you
want it to build a local checkout instead.

On NixOS the script refuses to run and tells you to use the module instead.

### Remove

- NixOS: set `programs.ember.enable = false` and rebuild.
- Script install: `./scripts/install.sh --uninstall`.

## Use

Import a script or an archive; Steam picks it up without a restart.

```sh
ember import ~/Downloads/1091500.zip     # an archive with manifests
ember import ~/Downloads/1245620.lua     # a bare script
```

Then install the game in Steam as usual.

### Store-page layer (opt-in)

Badges, themes and settings panels are drawn by `steamwebhelper`, not by the
client, so ember needs a DevTools (CDP) connection to that process. Steam never
opens that endpoint on its own, so ember ships a small preload shim that adds
`--remote-debugging-port` when the client spawns the webhelper — and nothing else.

```nix
programs.ember.cefDebug = true;   # NixOS; cefPort defaults to 8080
```

```sh
EMBER_CEF=1 steam-ember           # script installs
```

Then `ember ui status` shows the endpoint, its owner, and the page targets it can
see. Off by default on purpose: the port is unauthenticated, so any local process
can drive the webview while it is open.

| Command | What it does |
|---|---|
| `ember import <file.lua\|file.zip>` | Add a game: script, depot keys, manifest pins, manifests |
| `ember remove <appid>` | Drop an imported game and the manifests only it uses |
| `ember list` | Show what is imported and how many manifests are stored |
| `ember status` | Client, store and depotcache state |
| `ember ui [status]` | Store-page injection endpoint: port, targets, what is missing |
| `ember doctor` | Full check; the first thing to run when something is wrong |
| `ember update [--check]` | Update the library and CLI to the latest release |

### Where things live

| What | Path |
|---|---|
| Scripts | `~/.steam/steam/config/stplug-in/*.lua` |
| Manifest store | `~/.config/ember/manifests/` |
| Config | `~/.config/ember/config.yaml` |
| Log | `~/.ember.log` |

Scripts are plain text. A minimal one:

```
addappid(1245620)
addappid(1245620,1,"<64 hex depot key>")
setManifestid(1245620,"<manifest id>",<size in bytes>)
```

Dropping a file into the scripts folder is enough — ember reloads on change.

## Troubleshooting

Start here:

```sh
ember doctor
```

It checks that the library is attached to the client, that Steam's code signatures
still match, that your SteamID was captured, how many manifests you have against
how many the scripts expect, and whether the crash guard tripped. It exits
non-zero on failure.

| Symptom | Meaning |
|---|---|
| Games appear owned but the install shows 0 B | Steam built no depots for the app; run `ember doctor` |
| Install fails with "No internet connection" | That depot's manifest is not in the store; `ember doctor` reports how many are missing |
| Everything looks stock | The library is not attached; `ember doctor` says so under `core` |
| Steam starts but nothing works, once | The crash guard tripped after a failed start; it clears on the next launch |
| Broken after a Steam client update | Steam's code signatures moved. `ember doctor` names them; a new ember release is needed |

## Compatibility

**Do not run two client hooks at once.** Remove any other Steam library mod before
enabling ember — a standalone SLSsteam, or anything else that loads a library into
the client. They share the `stplug-in` folder and would both try to own licensing.

**ember does not modify Steam's UI yet.** Store-page badges, themes and settings
panels are rendered by a CEF/CDP injector speaking to the webhelper's DevTools
endpoint, not by a client hook; ember will grow that layer itself, in this repo
(`ember ui`). Until it lands there is nothing to enable and no third-party
framework to install.

**ember owns `programs.steam.package`.** If another module sets that option too,
Nix reports conflicting definitions. Use `programs.ember.steamPackage` rather than
defining `programs.steam.package` yourself.

**Anti-cheat.** Games using EAC or BattlEye can treat a modified client as
tampering. Avoid ember in multiplayer titles you care about.

**Flatpak Steam** is not supported by either install path; both assume a native
Steam install.

## How it works

ember is a shared library that Steam loads at startup. It answers Steam's ownership
and licence questions for the apps in your scripts, builds the install plan for
them, supplies depot keys, and stages manifests into Steam's depot cache.

A small CLI (`ember`) writes the scripts and the manifest store; the library reads
them. Nothing is patched on disk and there is no daemon.

## License

AGPL-3.0-only. Derived from [AceSLS/SLSsteam](https://github.com/AceSLS/SLSsteam);
the library source lives in [axioncs/ember-core](https://github.com/axioncs/ember-core).
