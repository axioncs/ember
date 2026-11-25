#!/bin/sh
# ember installer for Arch and Fedora.
#
#   curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh
#
# Flags:
#   --no-desktop-entry  install ember but do not add the "Wired Steam" entry
#   --no-restart        do not close and relaunch Steam after installing
#   --from-source       build the library here instead of downloading a release
#   --uninstall         remove everything this script installed
#
# Two launch paths exist side by side and neither shadows the other:
#
#   steam       / "Steam"        the distributor's client, untouched
#   steam-ember / "Wired Steam"  the same client with ember loaded
#
# Nothing here rewrites a packaged steam.desktop or puts a `steam` shim on
# PATH. An install made by an older version is un-patched instead: its shim is
# deleted and its steam.desktop restored from <name>.pre-ember.
#
# NixOS is not supported here; use the flake module instead.

set -eu

REPO="${EMBER_REPO:-https://github.com/axioncs/ember-core}"
RELEASES="${EMBER_RELEASES:-https://github.com/axioncs/ember/releases/download}"
RAW_CLI="${EMBER_RAW_URL:-https://raw.githubusercontent.com/axioncs/ember}"
INSTALL_CMD="curl -fsSL ${RAW_CLI}/main/scripts/install.sh"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ember"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ENTRY=1
RESTART=1
UNINSTALL=0
FROM_SOURCE="${EMBER_FROM_SOURCE:-0}"
# Test hooks: the OS check and the packaged desktop entry are read from these
# when set, so the install path can be exercised without Arch or Fedora.
OS_RELEASE="${EMBER_OS_RELEASE:-/etc/os-release}"
# Test hook: skip the build-dependency probe, which would otherwise prompt for
# sudo on a sandbox that has stub tools.
CHECK_DEPS="${EMBER_CHECK_DEPS:-1}"
MARKER="X-Ember-Alternative"


# Best-effort: the release tag, so the prebuilt download and `ember update` have
# something to compare against.
EMBER_VERSION="${EMBER_VERSION:-$(curl -fsSL https://api.github.com/repos/axioncs/ember/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)}"

usage() {
	cat <<'EOF'
ember installer for Arch and Fedora.

  curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh

Flags:
  --no-desktop-entry  install ember but do not add the "Wired Steam" entry
  --no-restart        do not close and relaunch Steam after installing
  --from-source       build the library here instead of downloading a release
  --uninstall         remove everything this script installed

Steam is never patched. The distributor's `steam` and its "Steam" entry keep
starting the vanilla client; ember adds `steam-ember` and a "Wired Steam"
entry beside them.

NixOS is not supported here; use the flake module instead.
EOF
}

for arg in "$@"; do
	case "$arg" in
		--desktop) ENTRY=1 ;;
		--no-desktop-entry|--no-desktop) ENTRY=0 ;;
		# Old name, kept so an `install-flags` file written by a previous
		# version still replays: it no longer skips a Steam patch (there is
		# none), it skips the Wired Steam entry.
		--no-steam-patch) ENTRY=0 ;;
		--no-restart) RESTART=0 ;;
		--from-source) FROM_SOURCE=1 ;;
		--uninstall) UNINSTALL=1 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'ember: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'ember: %s\n' "$*" >&2; exit 1; }

# Removes what an older installer did to Steam and this installer's own entry.
# Used by --uninstall and by any install that finds a legacy patch in place.
#
# The legacy shape was a ~/.local/bin/steam shim forwarding to steam-ember and
# a user-level steam.desktop whose Exec= had been rewritten in place. Both are
# undone here so the distributor's launch paths come back; a machine that never
# had them is unaffected and nothing is reported.
remove_launchers() {
	touched=0
	if [ -f "$BIN_DIR/steam" ] && grep -q 'ember' "$BIN_DIR/steam" 2>/dev/null; then
		rm -f "$BIN_DIR/steam"
		touched=1
	fi
	if [ -f "$BIN_DIR/steam.pre-ember" ]; then
		mv -f "$BIN_DIR/steam.pre-ember" "$BIN_DIR/steam"
		touched=1
	fi

	entry="$APPS_DIR/steam.desktop"
	if [ -f "$entry" ] && grep -q "$MARKER" "$entry" 2>/dev/null; then
		if [ -f "$entry.pre-ember" ]; then
			mv -f "$entry.pre-ember" "$entry"
		else
			rm -f "$entry"
		fi
		touched=1
	fi

	if [ -f "$APPS_DIR/wired-steam.desktop" ]; then
		rm -f "$APPS_DIR/wired-steam.desktop"
		touched=1
	fi
	[ -f "$entry.pre-ember" ] && rm -f "$entry.pre-ember"

	[ "$touched" = 1 ] && say "removed ember's launchers (Steam's own are untouched)"
	return 0
}

[ -r "$OS_RELEASE" ] || die "cannot read $OS_RELEASE"
# shellcheck disable=SC1090
. "$OS_RELEASE"

case "${ID:-} ${ID_LIKE:-}" in
	*nixos*)
		cat >&2 <<'EOF'
ember: this is NixOS. Do not use this script.

Add the flake input and enable the module instead:

  inputs.ember.url = "github:axioncs/ember";
  modules = [ ember.nixosModules.default ];
  programs.ember.enable = true;
EOF
		exit 1
		;;
esac

# The store-page badge is drawn by a companion process, not by the library: the
# core creates Steam's remote-debugging marker and rewrites the webhelper's port
# argument, but something has to speak DevTools to the page. On NixOS that is a
# systemd user unit declared in modules/nixos.nix. The script install has no
# module, so without this the endpoint is live and the badge never appears —
# "Steam has no ember at all" while the library demonstrably works.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

install_user_units() {
	command -v systemctl >/dev/null 2>&1 || {
		say "no systemd user manager; run 'ember ui watch' yourself"
		return 0
	}
	mkdir -p "$UNIT_DIR"
	# Type=simple + Restart=on-failure: the watcher blocks while Steam runs and
	# exits when it does, which is a normal shutdown, not a failure. Restart=
	# always would turn that into a restart loop.
	# The cloud-push service/timer are opt-in (a timer running `rclone sync`
	# against an unconfigured remote writes a journal entry every interval), so
	# they are installed but never enabled here. Arch/Fedora installs need them
	# as much as the NixOS module's machine does.
	cat > "$UNIT_DIR/ember-cloud-push.service" <<EOF2
[Unit]
Description=Push ember cloud saves to the configured rclone remote

[Service]
Type=oneshot
ExecStart=$BIN_DIR/ember cloud push
TimeoutStartSec=600
Nice=10
IOSchedulingClass=idle
EOF2
	cat > "$UNIT_DIR/ember-cloud-push.timer" <<EOF2
[Unit]
Description=Periodic ember cloud save push

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
Unit=ember-cloud-push.service

[Install]
WantedBy=timers.target
EOF2
	cat > "$UNIT_DIR/ember-ui-watch.service" <<EOF
[Unit]
Description=ember store-page badge watcher
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$BIN_DIR/ember ui watch --quiet
Restart=on-failure
RestartSec=5
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=default.target
EOF
	systemctl --user daemon-reload >/dev/null 2>&1 || true
	if systemctl --user enable --now ember-ui-watch.service >/dev/null 2>&1; then
		say "badge watcher enabled (ember-ui-watch.service)"
	else
		# Enabling needs a reachable user manager; an installer run over ssh or
		# from a non-graphical tty has none. Say so rather than reporting success,
		# because an inert unit is indistinguishable from a working badge.
		say "wrote $UNIT_DIR/ember-ui-watch.service but could not enable it"
		say "  enable it from your desktop session: systemctl --user enable --now ember-ui-watch.service"
	fi
}

remove_user_units() {
	command -v systemctl >/dev/null 2>&1 &&
		systemctl --user disable --now ember-ui-watch.service >/dev/null 2>&1 || true
	rm -f "$UNIT_DIR/ember-ui-watch.service" "$UNIT_DIR/ember-cloud-push.service" "$UNIT_DIR/ember-cloud-push.timer"
	command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true
	return 0
}

if [ "$UNINSTALL" = 1 ]; then
	say "removing ember"
	remove_user_units
	rm -f "$DATA_DIR/ember-core.so" "$DATA_DIR/ember-library-inject.so" \
		"$DATA_DIR/ember.lua" "$DATA_DIR/VERSION"
	rm -f "$DATA_DIR/ember-cdpd" "$DATA_DIR/badge.js"
	rm -f "$DATA_DIR/install-flags"
	rm -f "$BIN_DIR/steam-ember" "$BIN_DIR/ember"
	rmdir "$DATA_DIR" 2>/dev/null || true

	remove_launchers

	say "done"
	exit 0
fi

case "${ID:-} ${ID_LIKE:-}" in
	*arch*)   FAMILY=arch ;;
	*fedora*) FAMILY=fedora ;;
	*) die "unsupported distribution: ${PRETTY_NAME:-unknown} (Arch and Fedora only)" ;;
esac

say "distribution: $FAMILY"

need_pkgs() {
	[ "$#" -gt 0 ] || return 0
	say "installing build dependencies: $*"
	case "$FAMILY" in
		arch)   sudo pacman -S --needed --noconfirm "$@" ;;
		fedora) sudo dnf install -y "$@" ;;
	esac
}

# Runtime dependencies, needed by every install path: `ember import` shells out
# to unzip and the launcher is a Lua script.
command -v lua >/dev/null 2>&1 || die "lua is required for the ember command"
command -v unzip >/dev/null 2>&1 || die "unzip is required by 'ember import'"
command -v curl >/dev/null 2>&1 || die "curl is required to download ember"

# `ember cloud` shells out to rclone. It stays optional — a missing rclone only
# breaks the cloud command, and `ember doctor` reports it.
command -v rclone >/dev/null 2>&1 || say "rclone is not installed; 'ember cloud' will not work"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage"

# Downloads the release artifact for this tag. Returns non-zero when there is
# none, so the caller falls back to a source build.
prebuilt() {
	[ "$FROM_SOURCE" = 0 ] || return 1
	[ -n "${EMBER_VERSION:-}" ] || { say "no release tag resolved; building from source"; return 1; }
	[ "$(uname -m)" = "x86_64" ] || { say "no prebuilt for $(uname -m); building from source"; return 1; }

	url="$RELEASES/$EMBER_VERSION/ember-$EMBER_VERSION-x86_64-linux.tar.gz"
	say "downloading ember $EMBER_VERSION ($(uname -m))"
	curl -fsSL "$url" -o "$work/ember.tar.gz" 2>/dev/null || {
		say "no release artifact for $EMBER_VERSION; building from source"
		return 1
	}

	# The checksum is published beside the tarball. Verify it when it exists:
	# a truncated or swapped artifact must not be installed as a library that
	# loads into Steam.
	if curl -fsSL "$url.sha256" -o "$work/ember.sha256" 2>/dev/null; then
		expected="$(sed -n 's/^\([0-9a-f]\{64\}\).*/\1/p' "$work/ember.sha256" | head -1)"
		actual="$(sha256sum "$work/ember.tar.gz" | cut -d' ' -f1)"
		[ -n "$expected" ] || die "cannot parse the published checksum"
		[ "$expected" = "$actual" ] || die "checksum mismatch for $url (got $actual)"
	fi

	tar xzf "$work/ember.tar.gz" -C "$stage" || die "cannot unpack $url"
	[ -f "$stage/ember-core.so" ] || die "release artifact is missing ember-core.so"
	[ -f "$stage/ember.lua" ] || die "release artifact is missing ember.lua"
	return 0
}

# Builds the library from source and stages it with the CLI for this tag.
from_source() {
	missing=""
	if [ "$CHECK_DEPS" = 1 ]; then
	command -v g++ >/dev/null 2>&1 || missing="$missing gcc"
	command -v make >/dev/null 2>&1 || missing="$missing make"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	pkg-config --exists dbus-1 2>/dev/null || missing="$missing dbus"
	pkg-config --exists libcurl 2>/dev/null || missing="$missing curl"
	[ -f /usr/include/luajit-2.1/lua.hpp ] || missing="$missing luajit"
	fi

	if [ -n "$missing" ]; then
		case "$FAMILY" in
			arch)   need_pkgs base-devel pkgconf dbus curl luajit ;;
			fedora) need_pkgs gcc-c++ make pkgconf-pkg-config dbus-devel libcurl-devel luajit-devel ;;
		esac
	fi

	if [ -n "${EMBER_SRC:-}" ]; then
		say "using source at $EMBER_SRC"
		cp -a "$EMBER_SRC/." "$work/src"
	else
		say "fetching $REPO"
		git clone --depth 1 "$REPO" "$work/src" || die "clone failed; set EMBER_SRC to a local checkout"
	fi

	say "building"
	make -C "$work/src" -j"$(nproc)" bin/ember-core.so bin/ember-library-inject.so
	install -m755 "$work/src/bin/ember-core.so" "$stage/ember-core.so"
	install -m755 "$work/src/bin/ember-library-inject.so" \
		"$stage/ember-library-inject.so"

	# The CLI is one file; fetching it avoids cloning a second repository. Take
	# it from the same tag as the version being recorded, so a release install
	# cannot pair a new library with an older CLI.
	say "fetching the CLI"
	cli="$RAW_CLI/main/packages/cli/ember.lua"
	[ -n "${EMBER_VERSION:-}" ] && cli="$RAW_CLI/$EMBER_VERSION/packages/cli/ember.lua"
	curl -fsSL "$cli" -o "$stage/ember.lua" ||
		curl -fsSL "$RAW_CLI/main/packages/cli/ember.lua" -o "$stage/ember.lua" ||
		die "could not fetch the CLI"
}

if prebuilt; then
	say "using the prebuilt release"
else
	from_source
fi

# A source build records its commit. Without it, `ember update` compares the
# latest tag with the latest tag and calls a source install current forever.
if [ ! -f "$stage/VERSION" ]; then
	rev=""
	[ -n "${EMBER_SRC:-}" ] && rev="$(git -C "$EMBER_SRC" rev-parse HEAD 2>/dev/null || true)"
	if [ -n "$rev" ]; then
		printf '%s+source-%s\n' "${EMBER_VERSION:-unknown}" "$(printf '%s' "$rev" | cut -c1-7)" > "$stage/VERSION"
	else
		printf '%s\n' "${EMBER_VERSION:-unknown}" > "$stage/VERSION"
	fi
fi

say "installing to $DATA_DIR"
mkdir -p "$DATA_DIR" "$BIN_DIR"
install -m755 "$stage/ember-core.so" "$DATA_DIR/ember-core.so"
[ -f "$stage/ember-library-inject.so" ] &&
	install -m755 "$stage/ember-library-inject.so" \
		"$DATA_DIR/ember-library-inject.so"
install -m644 "$stage/ember.lua" "$DATA_DIR/ember.lua"
install -m644 "$stage/VERSION" "$DATA_DIR/VERSION"

[ -f "$stage/ember-cdpd" ] && install -m755 "$stage/ember-cdpd" "$DATA_DIR/ember-cdpd"
[ -f "$stage/badge.js" ] && install -m644 "$stage/badge.js" "$DATA_DIR/badge.js"

cat > "$BIN_DIR/ember" <<EOF
#!/bin/sh
exec lua "$DATA_DIR/ember.lua" "\$@"
EOF
chmod 755 "$BIN_DIR/ember"

# The launcher resolves the distributor's steam itself, never another ember
# executable, so `steam-ember` can never re-enter itself.
cat > "$BIN_DIR/steam-ember" <<EOF
#!/bin/sh
# generated by ember's install.sh; removed by --uninstall
self="\$(readlink -f "\$0")"
legacy_shim="\$(readlink -f "$BIN_DIR/steam" 2>/dev/null || true)"
real=""
old_ifs=\$IFS
IFS=:
for dir in \$PATH; do
	[ -x "\$dir/steam" ] || continue
	resolved="\$(readlink -f "\$dir/steam" 2>/dev/null || true)"
	[ -n "\$resolved" ] || continue
	[ "\$resolved" = "\$self" ] && continue
	[ -n "\$legacy_shim" ] && [ "\$resolved" = "\$legacy_shim" ] && continue
	real="\$dir/steam"
	break
done
IFS=\$old_ifs
[ -n "\$real" ] || { printf 'steam-ember: no steam binary on PATH\n' >&2; exit 127; }

# Both objects go in LD_AUDIT, colon-separated and in this order: the libcurl
# redirector first, then the audit library. The core binds the client's exec
# calls itself to rewrite the webhelper's remote-debugging argument, so nothing
# needs LD_PRELOAD and the port is not ours to pick.
AUDIT="$DATA_DIR/ember-library-inject.so:$DATA_DIR/ember-core.so"
if [ "\${EMBER_CEF:-1}" != 0 ]; then
	exec env LD_AUDIT="\$AUDIT" "\$real" "\$@"
fi
exec env -u LD_AUDIT "\$real" "\$@"
EOF
chmod 755 "$BIN_DIR/steam-ember"

# A second desktop entry beside the packaged one, with its own file name, so the
# "Steam" entry the distributor ships keeps pointing at the vanilla client and
# `steam://` links keep working exactly as before. Exec names the launcher on
# PATH rather than an absolute path: the launcher is the same file, and a name
# survives a changed XDG_BIN_HOME.
install_wired_entry() {
	mkdir -p "$APPS_DIR"
	entry="$APPS_DIR/wired-steam.desktop"
	cat > "$entry" <<EOF
[Desktop Entry]
$MARKER=true
Type=Application
Name=Wired Steam
GenericName=Game Store
Comment=Steam with ember loaded, for games ember added
Exec=steam-ember %U
Icon=steam
Terminal=false
Categories=Game;
StartupWMClass=Steam
EOF
	chmod 644 "$entry"
	say "wrote $entry"

	command -v update-desktop-database >/dev/null 2>&1 &&
		update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}

if [ "$ENTRY" = 1 ]; then
	# Undo an older install's shim and rewritten steam.desktop first, so an
	# upgrade leaves exactly one launch model: vanilla Steam plus Wired Steam.
	remove_launchers
	install_wired_entry
	say "Steam's own launchers are untouched; start Wired Steam for ember"
	: > "$DATA_DIR/install-flags"
else
	remove_launchers
	say "skipping the Wired Steam entry (--no-desktop-entry)"
	# `ember update` replays this, so an update cannot add it back.
	printf '%s\n' '--no-desktop-entry' > "$DATA_DIR/install-flags"
fi


# The badge is a separate process from the library, so it is installed whether or
# not the Wired Steam entry was written: --no-desktop-entry is about the launch
# path, not about turning the UI layer off.
install_user_units

# A running client keeps the library that was loaded at its start, so a fresh
# install only takes effect on the next launch.
steam_running() {
	pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1
}

restart_steam() {
	if ! command -v pgrep >/dev/null 2>&1; then
		say "cannot detect Steam (no pgrep); start it with steam-ember"
		return 0
	fi

	if steam_running; then
		say "closing Steam"
		"$BIN_DIR/steam-ember" -shutdown </dev/null >/dev/null 2>&1 || true
		waited=0
		while steam_running && [ "$waited" -lt 20 ]; do
			sleep 1
			waited=$((waited + 1))
		done
		if steam_running; then
			say "Steam did not exit; it picks up ember when you next start it"
			return 0
		fi
	fi

	# Detached, and with stdin closed: the installer is often running from a
	# pipe, and a background child that inherits it eats the rest of the script.
	say "starting Steam with ember"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$BIN_DIR/steam-ember" </dev/null >/dev/null 2>&1 &
	else
		nohup "$BIN_DIR/steam-ember" </dev/null >/dev/null 2>&1 &
	fi
}

# Offered before the restart, because Steam picks up config at start and the
# user is already at a terminal. Reads the remote list from rclone itself, so
# there is nothing to keep in sync here and no provider-specific code.
#
# The login is NOT part of this. `rclone config` does that, in the user's
# browser, and writes the token to ~/.config/rclone/rclone.conf — ember only
# ever reads a remote name out of config.yaml. Non-interactive installs skip
# the whole thing.
setup_cloud() {
	CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ember/config.yaml"

	if [ ! -t 0 ] || [ "${NONINTERACTIVE:-0}" = 1 ]; then
		return 0
	fi
	if ! command -v rclone >/dev/null 2>&1; then
		printf '\nCloud saves: install rclone and run `rclone config` to sync saves\n'
		printf 'between machines. Skipping for now.\n'
		return 0
	fi

	# A remote already recorded in config.yaml is left alone; re-running the
	# installer must not silently move the user's saves to a different drive.
	if [ -f "$CONFIG_FILE" ] && grep -q '^CloudRemote: *[^"[:space:]]' "$CONFIG_FILE" 2>/dev/null; then
		return 0
	fi

	printf '\nCloud saves (optional)\n'
	printf '  ember keeps saves for added games in ~/.config/ember/cloud.\n'
	printf '  Pick a storage to sync them to, so another machine can pick up\n'
	printf '  where you left off. Your games and Steam stay untouched.\n\n'

	remotes=$(rclone listremotes 2>/dev/null | sed 's/:$//')
	if [ -z "$remotes" ]; then
		printf '  No rclone remotes are configured yet.\n'
		printf '  Run:  rclone config\n'
		printf '  Then: ember cloud setup\n\n'
		return 0
	fi

	printf '  Available remotes:\n'
	printf '    0) skip - saves stay on this machine\n'
	n=1
	IFS='
'
	for r in $remotes; do
		printf '    %d) %s\n' "$n" "$r"
		n=$((n + 1))
	done
	unset IFS
	printf '\n  Select [0]: '

	choice=""
	read -r choice || choice="0"
	[ -n "$choice" ] || choice="0"

	case "$choice" in
		0) printf '  Skipped. Set it later with `ember cloud setup`.\n\n'; return 0 ;;
		''|*[!0-9]*) printf '  Not a number; skipping.\n\n'; return 0 ;;
	esac

	selected=$(printf '%s\n' "$remotes" | sed -n "${choice}p")
	if [ -z "$selected" ]; then
		printf '  No such remote; skipping.\n\n'
		return 0
	fi

	mkdir -p "$(dirname "$CONFIG_FILE")"
	if [ -f "$CONFIG_FILE" ]; then
		cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
	fi
	# Rewrite the key rather than append: a re-run must replace a stale value,
	# and appending would leave two CloudRemote lines where the first wins.
	if grep -q '^CloudRemote:' "$CONFIG_FILE" 2>/dev/null; then
		tmp="${CONFIG_FILE}.tmp"
		sed "s|^CloudRemote:.*|CloudRemote: $selected|" "$CONFIG_FILE" > "$tmp" \
			&& mv "$tmp" "$CONFIG_FILE"
	else
		printf '\n# rclone remote ember cloud syncs saves with\nCloudRemote: %s\n' \
			"$selected" >> "$CONFIG_FILE"
	fi
	printf '  Cloud saves will sync to %s\n' "$selected"
	printf '  Upload with: ember cloud push\n\n'
}

if [ "$UNINSTALL" = 0 ]; then
	setup_cloud
fi

if [ "$ENTRY" = 1 ] && [ "$RESTART" = 1 ]; then
	restart_steam
elif [ "$ENTRY" = 1 ]; then
	say "start Steam again to load ember (--no-restart)"
fi

say "done"
printf '\n  library:  %s\n  cli:      %s\n  launcher: %s\n\n' \
	"$DATA_DIR/ember-core.so" "$BIN_DIR/ember" "$BIN_DIR/steam-ember"
printf '`steam` and the "Steam" entry still start the vanilla client.\n'
printf 'Start the "Wired Steam" entry (or `steam-ember`) to play with ember.\n'
printf 'Undo with: %s | sh -s -- --uninstall\n' "$INSTALL_CMD"
printf 'Then: ember doctor\n'
