#!/bin/sh
# ember installer for Arch and Fedora.
#
#   curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh
#
# Flags:
#   --no-steam-patch  install ember but leave Steam's launchers alone
#   --no-restart      do not close and relaunch Steam after installing
#   --from-source     build the library here instead of downloading a release
#   --uninstall       remove everything this script installed
#
# By default Steam is patched so every launch starts with ember: a user-level
# steam.desktop that shadows the packaged one, and a `steam` shim on PATH. Both
# carry a marker line and are undone by --uninstall.
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
PATCH=1
RESTART=1
UNINSTALL=0
FROM_SOURCE="${EMBER_FROM_SOURCE:-0}"
# Test hooks: the OS check and the packaged desktop entry are read from these
# when set, so the install path can be exercised without Arch or Fedora.
OS_RELEASE="${EMBER_OS_RELEASE:-/etc/os-release}"
MARKER="X-Ember-Alternative"


# Best-effort: the release tag, so the prebuilt download and `ember update` have
# something to compare against.
EMBER_VERSION="${EMBER_VERSION:-$(curl -fsSL https://api.github.com/repos/axioncs/ember/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)}"

usage() {
	cat <<'EOF'
ember installer for Arch and Fedora.

  curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh

Flags:
  --no-steam-patch  install ember but leave Steam's launchers alone
  --no-restart      do not close and relaunch Steam after installing
  --from-source     build the library here instead of downloading a release
  --uninstall       remove everything this script installed

By default Steam is patched so every launch starts with ember: a user-level
steam.desktop that shadows the packaged one, and a `steam` shim on PATH. Both
carry a marker line and are restored by --uninstall.

NixOS is not supported here; use the flake module instead.
EOF
}

for arg in "$@"; do
	case "$arg" in
		--desktop) PATCH=1 ;;
		--no-steam-patch|--no-desktop) PATCH=0 ;;
		--no-restart) RESTART=0 ;;
		--from-source) FROM_SOURCE=1 ;;
		--uninstall) UNINSTALL=1 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'ember: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'ember: %s\n' "$*" >&2; exit 1; }

# Undoes only what carries ember's markers, restoring anything that was kept
# beside it. Used by --uninstall and by an install that opts out of patching.
unpatch_steam() {
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

	[ "$touched" = 1 ] && say "removed the Steam patch"
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

if [ "$UNINSTALL" = 1 ]; then
	say "removing ember"
	rm -f "$DATA_DIR/ember-core.so" "$DATA_DIR/ember.lua" "$DATA_DIR/VERSION"
	rm -f "$DATA_DIR/ember-cef.so" "$DATA_DIR/ember-cdpd" "$DATA_DIR/badge.js"
	rm -f "$DATA_DIR/install-flags"
	rm -f "$BIN_DIR/steam-ember" "$BIN_DIR/ember"
	rmdir "$DATA_DIR" 2>/dev/null || true

	unpatch_steam

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
	command -v g++ >/dev/null 2>&1 || missing="$missing gcc"
	command -v make >/dev/null 2>&1 || missing="$missing make"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	pkg-config --exists dbus-1 2>/dev/null || missing="$missing dbus"
	pkg-config --exists libcurl 2>/dev/null || missing="$missing curl"
	[ -f /usr/include/luajit-2.1/lua.hpp ] || missing="$missing luajit"

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
	make -C "$work/src" -j"$(nproc)" audit-libs
	install -m755 "$work/src/bin/SLSsteam.so" "$stage/ember-core.so"

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

[ -f "$stage/VERSION" ] || printf '%s\n' "${EMBER_VERSION:-unknown}" > "$stage/VERSION"

say "installing to $DATA_DIR"
mkdir -p "$DATA_DIR" "$BIN_DIR"
install -m755 "$stage/ember-core.so" "$DATA_DIR/ember-core.so"
install -m644 "$stage/ember.lua" "$DATA_DIR/ember.lua"
install -m644 "$stage/VERSION" "$DATA_DIR/VERSION"

# Optional: the preload shim that opens the webhelper's DevTools endpoint.
[ -f "$stage/ember-cef.so" ] && install -m755 "$stage/ember-cef.so" "$DATA_DIR/ember-cef.so"
[ -f "$stage/ember-cdpd" ] && install -m755 "$stage/ember-cdpd" "$DATA_DIR/ember-cdpd"
[ -f "$stage/badge.js" ] && install -m644 "$stage/badge.js" "$DATA_DIR/badge.js"

cat > "$BIN_DIR/ember" <<EOF
#!/bin/sh
exec lua "$DATA_DIR/ember.lua" "\$@"
EOF
chmod 755 "$BIN_DIR/ember"

# The launcher resolves the distributor's steam itself, skipping this install's
# own shims, so a `steam` shim on PATH can exec it without recursing.
cat > "$BIN_DIR/steam-ember" <<EOF
#!/bin/sh
# generated by ember's install.sh; removed by --uninstall
self="\$(readlink -f "\$0")"
shim="\$(readlink -f "$BIN_DIR/steam" 2>/dev/null || true)"
real=""
old_ifs=\$IFS
IFS=:
for dir in \$PATH; do
	[ -x "\$dir/steam" ] || continue
	resolved="\$(readlink -f "\$dir/steam" 2>/dev/null || true)"
	[ -n "\$resolved" ] || continue
	[ "\$resolved" = "\$self" ] && continue
	[ -n "\$shim" ] && [ "\$resolved" = "\$shim" ] && continue
	real="\$dir/steam"
	break
done
IFS=\$old_ifs
[ -n "\$real" ] || { printf 'steam-ember: no steam binary on PATH\n' >&2; exit 127; }

# The badge agent is started here and again by the shim (EMBER_AGENT): the first
# covers a launch through this script, the second covers anything that runs the
# client directly. The agent's lock makes the duplicate a no-op.
if [ "\${EMBER_CEF:-1}" != 0 ] && [ -f "$DATA_DIR/ember-cef.so" ]; then
	"$BIN_DIR/ember" ui watch --quiet >/dev/null 2>&1 &
	exec env LD_AUDIT="$DATA_DIR/ember-core.so" \\
		LD_PRELOAD="$DATA_DIR/ember-cef.so" \\
		EMBER_CEF_PORT="\${EMBER_CEF_PORT:-8080}" \\
		EMBER_AGENT="$BIN_DIR/ember" \\
		"\$real" "\$@"
fi
exec env LD_AUDIT="$DATA_DIR/ember-core.so" "\$real" "\$@"
EOF
chmod 755 "$BIN_DIR/steam-ember"

# Steam itself, as typed in a shell or started by a session that ignores desktop
# files. It only forwards: the launcher owns the resolution and the environment.
patch_steam_command() {
	if [ -e "$BIN_DIR/steam" ] && ! grep -q 'ember' "$BIN_DIR/steam" 2>/dev/null; then
		mv -f "$BIN_DIR/steam" "$BIN_DIR/steam.pre-ember"
		say "kept the existing $BIN_DIR/steam as steam.pre-ember"
	fi
	if [ ! -e "$BIN_DIR/steam" ]; then
		cat > "$BIN_DIR/steam" <<EOF
#!/bin/sh
# generated by ember's install.sh; removed by --uninstall
exec "$BIN_DIR/steam-ember" "\$@"
EOF
		chmod 755 "$BIN_DIR/steam"
	fi
	say "wrote $BIN_DIR/steam"
	case ":$PATH:" in
		*":$BIN_DIR:"*) : ;;
		*) say "note: $BIN_DIR is not on PATH, so \`steam\` keeps starting the unpatched client" ;;
	esac
}

# The desktop entry is the path a dock, the applications menu and steam:// links
# take. A user-level file with the same name shadows the packaged one, so no
# root and no pacman-managed file is touched.
patch_steam_entry() {
	entry="$APPS_DIR/steam.desktop"
	system_entry="${EMBER_STEAM_DESKTOP:-}"
	if [ -z "$system_entry" ]; then
		for candidate in /usr/share/applications/steam.desktop /usr/local/share/applications/steam.desktop; do
			[ -f "$candidate" ] && system_entry="$candidate" && break
		done
	fi

	if [ -z "$system_entry" ] || [ ! -f "$system_entry" ]; then
		say "no packaged steam.desktop found; skipping it (flatpak Steam cannot be hooked this way)"
		return 0
	fi

	mkdir -p "$APPS_DIR"
	if [ -f "$entry" ] && ! grep -q "$MARKER" "$entry" 2>/dev/null; then
		cp -f "$entry" "$entry.pre-ember"
		say "kept the existing override as $entry.pre-ember"
	fi
	# Every Exec goes through the launcher, keeping its arguments (%U included);
	# `Exec=env ... steam` and `-bigpicture` variants survive the rewrite.
	sed -e "s|^Exec=[^ ]*|Exec=$BIN_DIR/steam-ember|" \
		-e "/^\[Desktop Entry\]/a $MARKER=true" \
		"$system_entry" > "$entry.tmp"
	mv -f "$entry.tmp" "$entry"
	say "wrote $entry"

	command -v update-desktop-database >/dev/null 2>&1 &&
		update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}

if [ "$PATCH" = 1 ]; then
	patch_steam_command
	patch_steam_entry
	: > "$DATA_DIR/install-flags"
else
	unpatch_steam
	say "leaving Steam alone (--no-steam-patch)"
	# `ember update` replays this, so an update cannot turn the patch back on.
	printf '%s\n' '--no-steam-patch' > "$DATA_DIR/install-flags"
fi

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

if [ "$PATCH" = 1 ] && [ "$RESTART" = 1 ]; then
	restart_steam
elif [ "$PATCH" = 1 ]; then
	say "start Steam again to load ember (--no-restart)"
fi

say "done"
printf '\n  library:  %s\n  cli:      %s\n  launcher: %s\n\n' \
	"$DATA_DIR/ember-core.so" "$BIN_DIR/ember" "$BIN_DIR/steam-ember"
if [ "$PATCH" = 1 ]; then
	printf 'Steam now starts with ember from the desktop entry and from `steam`.\n'
	printf 'Undo with: %s | sh -s -- --uninstall\n' "$INSTALL_CMD"
else
	printf 'Launch Steam with `steam-ember`; re-run without --no-steam-patch to make it the default.\n'
fi
printf 'Then: ember doctor\n'
