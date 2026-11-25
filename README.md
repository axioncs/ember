# ember

Play and install Steam games your account doesn't own, with cloud saves that
follow you between machines.

ember attaches to Steam at launch and answers its questions about those games.
Nothing inside your Steam installation is modified, and there is no background
service.

## Install

### NixOS

```nix
{
  inputs.ember.url = "github:axioncs/ember";

  # add ember.nixosModules.default to your modules, then:
  programs.ember.enable = true;
}
```

Rebuild, and Steam starts with ember. `programs.ember.enable = false` and a
rebuild puts everything back.

A NixOS rebuild downloads the published core rather than compiling it, the same
way the script install does on Arch and Fedora. Building from the flake input
instead is one option away:

```nix
programs.ember.package = ember.packages.${system}.coreSource;
```

### Arch, Fedora and derivatives

```sh
curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh
```

That installs the CLI and adds a second launch path; it asks about syncing
saves at the end — see [Saves](#saves). Steam's own launchers are never
touched:

| | Launcher | Desktop entry | What it starts |
|---|---|---|---|
| Vanilla | `steam` | **Steam** | the distributor's client |
| ember | `steam-ember` | **Wired Steam** | the same client with ember loaded |

Start **Wired Steam** to play with ember. `steam://` links, autostart and
anything else that names `steam` keep launching the vanilla client, so ember is
opt-in per launch.

## Adding a game

Two things: a script that tells ember which game this is, and the game's
manifest files. Both usually arrive together as a zip.

```sh
ember import ~/Downloads/1091500.zip   # script + manifests
ember import ~/Downloads/1245620.lua   # script only
```

Then install the game in Steam as usual. No restart needed.

A minimal script is one line per depot, with its key and the manifest file that
goes with it:

```
addappid(1245620)
addappid(1245620,1,"<64 hex depot key>")
setManifestid(1245620,"<manifest id>",<size in bytes>)
```

Dropping a `.lua` into `~/.steam/steam/config/stplug-in/` does the same thing;
ember picks up changes there on its own.

`ember list` shows what's imported, `ember remove <appid>` takes one back out.

## Saves

Steam refuses cloud saves for games your account doesn't own. ember keeps those
saves on disk instead and can sync them to storage you choose, so a second
machine picks up where you left off.

Games you *do* own are never touched — their saves keep going to Steam.

### Pick a storage

The sync uses [rclone](https://rclone.org), which supports Google Drive,
OneDrive, Dropbox, S3, WebDAV, a NAS or a plain folder. Run it once:

```sh
rclone config
```

**This is where you log in.** rclone opens your browser, you approve access, and
it stores the token in `~/.config/rclone/rclone.conf`. ember never sees your
password or that token — it only reads the remote's name. Nothing else ever asks
you to log in.

Then tell ember which one to use:

```sh
ember cloud setup      # lists your remotes, pick one
```

On NixOS, set it declaratively instead:

```nix
programs.ember.cloudRemote = "gdrive";
programs.ember.cloudFolder = "ember-cloud";   # optional, this is the default
```

### Use it

```sh
ember cloud push       # upload your saves
ember cloud pull       # download them, onto this machine or a new one
ember cloud status     # what's local, what's remote
```

`push` makes the remote match your machine, so a save you delete locally is
deleted remotely too. `pull` does the reverse. If two machines edited the same
save independently, whichever synced last wins.

Nothing uploads on its own — you run the command. If the target folder already
holds saves for a different Steam account, `push` refuses rather than deleting
them, because `sync` cannot tell those apart from stale copies of yours.

### Turn it off

```nix
programs.ember.cloud = false;    # NixOS
```

Or `Cloud: no` in `~/.config/ember/config.yaml`. Added games then get no cloud
at all.

### Changing remotes

Remotes belong to rclone, so switching storage is `rclone config` to add the new
one, then `ember cloud setup` to point at it. Your saves are plain files under
`~/.config/ember/cloud/`, so anything that copies a folder can back them up too.

## Store-page badges

Store pages can show a ProtonDB badge and load community themes. Steam draws
those pages in a separate browser process that ember talks to over a local
debugging port.

It's on by default. To leave it alone:

```nix
programs.ember.cefDebug = false;    # NixOS
```

`ember ui status` reports the connection, `ember ui attach` draws once by hand.

## Commands

| Command | What it does |
|---|---|
| `ember import <file>` | Add a game from a `.lua` or `.zip` |
| `ember remove <appid>` | Remove a game and its manifests |
| `ember list` | Show what's imported |
| `ember status` | Client and store state |
| `ember cloud setup` | Choose where saves sync to |
| `ember cloud push` | Upload saves |
| `ember cloud pull` | Download saves |
| `ember cloud status` | Local vs remote saves |
| `ember doctor` | Check everything; run this first when something's wrong |
| `ember update` | Update ember |
| `ember ui status` | Store-page badge connection |

## When something's wrong

```sh
ember doctor
```

It checks each layer and says what's broken. Common ones:

| What you see | What it means |
|---|---|
| Games look owned but install shows 0 B | Steam built no download plan; `ember doctor` says why |
| Install fails with "No internet connection" | The game's manifest files aren't in the store; `ember doctor` counts what's missing |
| Steam looks completely normal | ember isn't attached — launch through `steam-ember` |
| Nothing works for one launch | ember's crash guard tripped; it clears on the next start |
| Broken after a Steam update | Steam's internals moved and ember needs an update |

## Requirements and limits

- Linux x86_64 with native Steam. Flatpak Steam can't be hooked this way.
- Don't run ember alongside another Steam library mod. They fight over the same
  files.
- Games with EAC or BattlEye anti-cheat may treat a modified client as tampering.
  Avoid ember in multiplayer games you care about.
- ember is AGPL-3.0-only.
