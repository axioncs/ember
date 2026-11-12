#!/bin/sh
# ember installer for Arch and Fedora.
#
#   curl -fsSL https://raw.githubusercontent.com/axioncs/ember/main/scripts/install.sh | sh
#
# Flags:
#   --desktop     also point the Steam desktop entry at ember
#   --uninstall   remove everything this script installed
#
# NixOS is not supported here; use the flake module instead.

set -eu

REPO="${EMBER_REPO:-https://github.com/axioncs/ember-core}"
CLI_URL="${EMBER_CLI_URL:-https://raw.githubusercontent.com/axioncs/ember/main/packages/cli/ember.lua}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ember"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP=0
UNINSTALL=0

# Best-effort: the release tag, so `ember update` has something to compare against.
EMBER_VERSION="${EMBER_VERSION:-$(curl -fsSL https://api.github.com/repos/axioncs/ember/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)}"

for arg in "$@"; do
	case "$arg" in
		--desktop) DESKTOP=1 ;;
		--uninstall) UNINSTALL=1 ;;
		-h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'ember: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'ember: %s\n' "$*" >&2; exit 1; }

[ -r /etc/os-release ] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release

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
	rm -f "$BIN_DIR/steam-ember" "$BIN_DIR/ember"
	rmdir "$DATA_DIR" 2>/dev/null || true

	entry="$HOME/.local/share/applications/steam.desktop"
	if [ -f "$entry" ] && grep -q 'LD_AUDIT=.*ember-core' "$entry"; then
		rm -f "$entry"
		say "removed the desktop override"
	fi

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

missing=""
command -v g++ >/dev/null 2>&1 || missing="$missing gcc"
command -v make >/dev/null 2>&1 || missing="$missing make"
command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
pkg-config --exists dbus-1 2>/dev/null || missing="$missing dbus"
pkg-config --exists libcurl 2>/dev/null || missing="$missing curl"
[ -f /usr/include/luajit-2.1/lua.hpp ] || missing="$missing luajit"
command -v unzip >/dev/null 2>&1 || missing="$missing unzip"

if [ -n "$missing" ]; then
	case "$FAMILY" in
		arch)   need_pkgs base-devel pkgconf dbus curl luajit lua unzip ;;
		fedora) need_pkgs gcc-c++ make pkgconf-pkg-config dbus-devel libcurl-devel luajit-devel lua unzip ;;
	esac
fi

command -v lua >/dev/null 2>&1 || die "lua is required for the ember command"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${EMBER_SRC:-}" ]; then
	say "using source at $EMBER_SRC"
	cp -a "$EMBER_SRC/." "$work/src"
else
	say "fetching $REPO"
	git clone --depth 1 "$REPO" "$work/src" || die "clone failed; set EMBER_SRC to a local checkout"
fi

say "building"
make -C "$work/src" -j"$(nproc)" audit-libs

say "installing to $DATA_DIR"
mkdir -p "$DATA_DIR" "$BIN_DIR"
install -m755 "$work/src/bin/SLSsteam.so" "$DATA_DIR/ember-core.so"

# The CLI is one file; fetching it avoids cloning a second repository.
say "installing the CLI"
curl -fsSL "$CLI_URL" -o "$DATA_DIR/ember.lua" || die "could not fetch $CLI_URL"

cat > "$BIN_DIR/ember" <<EOF
#!/bin/sh
exec lua "$DATA_DIR/ember.lua" "\$@"
EOF
chmod 755 "$BIN_DIR/ember"

printf '%s\n' "${EMBER_VERSION:-unknown}" > "$DATA_DIR/VERSION"

cat > "$BIN_DIR/steam-ember" <<EOF
#!/bin/sh
exec env LD_AUDIT="$DATA_DIR/ember-core.so" steam "\$@"
EOF
chmod 755 "$BIN_DIR/steam-ember"

if [ "$DESKTOP" = 1 ]; then
	entry="$HOME/.local/share/applications/steam.desktop"
	system_entry=""
	for candidate in /usr/share/applications/steam.desktop /var/lib/flatpak/exports/share/applications/steam.desktop; do
		[ -f "$candidate" ] && system_entry="$candidate" && break
	done
	[ -n "$system_entry" ] || die "no system steam.desktop found; launch with steam-ember instead"

	mkdir -p "$(dirname "$entry")"
	sed "s|^Exec=steam|Exec=env LD_AUDIT=$DATA_DIR/ember-core.so steam|" \
		"$system_entry" > "$entry"
	say "wrote $entry (delete it to revert)"
fi

say "done"
printf '\n  library:  %s\n  cli:      %s\n  launcher: %s\n\n' \
	"$DATA_DIR/ember-core.so" "$BIN_DIR/ember" "$BIN_DIR/steam-ember"
printf 'Launch Steam with `steam-ember`, or re-run with --desktop to make it the default.\n'
printf 'Then: ember doctor\n'
