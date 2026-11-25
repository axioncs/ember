#!/bin/sh
# Functional test for scripts/install.sh.
#
# Builds a sandbox HOME with stub tools, runs the installer against it, and
# asserts the launch model the docs promise:
#
#   steam       / "Steam"        untouched (no shim, no user steam.desktop)
#   steam-ember / "Wired Steam"  written, executable, and it resolves the real
#                                steam rather than re-entering itself
#
# Then it plants a legacy install (shim + patched steam.desktop with a
# .pre-ember backup) and asserts a re-run restores vanilla Steam, and that
# --uninstall removes only ember's own files.
#
# Run: sh scripts/test-install.sh

set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(readlink -f "$repo")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
check() {
	desc="$1"
	shift
	if "$@"; then
		pass=$((pass + 1))
		printf 'ok   %s\n' "$desc"
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n' "$desc"
	fi
}
file_has() { grep -q -- "$2" "$1" 2>/dev/null; }
missing() { [ ! -e "$1" ]; }
present() { [ -e "$1" ]; }

export HOME="$work/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_BIN_HOME="$HOME/.local/bin"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_BIN_HOME" "$XDG_CONFIG_HOME"

# --- stubs ------------------------------------------------------------------
# Only what the installer invokes. `systemctl` fails so nothing reaches the
# real user manager; `pgrep` fails so the restart step is skipped.
stub="$work/stub"
mkdir -p "$stub"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$stub/systemctl"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$stub/pgrep"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$stub/update-desktop-database"
cat > "$stub/curl" <<'EOF'
#!/bin/sh
# Serve the CLI file; everything else (release API, artifacts) fails so the
# installer takes the --from-source path.
case "$*" in
	*-o*) out=""
	      prev=""
	      for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
	      printf '%s\n' '-- stub cli' > "$out" ;;
esac
exit 0
EOF
cat > "$stub/make" <<'EOF'
#!/bin/sh
# The real Makefile builds the two libraries; the sandbox only needs the files.
# install.sh invokes make with -C <src>, so write the stubs into that directory
# rather than the caller's cwd.
dir="."
prev=""
for arg in "$@"; do
	if [ "$prev" = "-C" ]; then
		dir="$arg"
		prev=""
		continue
	fi
	if [ "$arg" = "-C" ]; then prev="$arg"; fi
done
mkdir -p "$dir/bin"
printf 'stub' > "$dir/bin/ember-core.so"
printf 'stub' > "$dir/bin/ember-library-inject.so"
exit 0
EOF
chmod 755 "$stub"/*
PATH="$stub:$PATH"
export PATH

# The installer checks for lua/unzip/curl; lua and unzip are never executed on
# this path, so a stub that only exists is enough.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$stub/lua"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$stub/unzip"
chmod 755 "$stub/lua" "$stub/unzip"

# A fake distributor steam that records how it was started.
syst="$work/sysbin"
mkdir -p "$syst"
cat > "$syst/steam" <<EOF
#!/bin/sh
printf 'LD_AUDIT=%s\n' "\${LD_AUDIT:-}" > "$work/launched"
printf 'argv=%s\n' "\$*" >> "$work/launched"
EOF
chmod 755 "$syst/steam"
PATH="$syst:$stub:$PATH"
export PATH

printf 'ID=arch\nID_LIKE=arch\nPRETTY_NAME="Arch Linux"\n' > "$work/os-release"

export EMBER_OS_RELEASE="$work/os-release"
export EMBER_SRC="${EMBER_CORE_SRC:-$repo/../ember-core}"
export EMBER_FROM_SOURCE=1
export EMBER_CHECK_DEPS=0

run_install() {
	if sh "$repo/scripts/install.sh" --from-source --no-restart "$@" \
		>"$work/install.log" 2>&1; then
		return 0
	fi
	# set -e exits before the caller can print the log; make the failure readable.
	printf '\n--- install log (failed) ---\n' >&2
	cat "$work/install.log" >&2
	return 1
}

# --- first install ----------------------------------------------------------
run_install

echo "--- install log"
cat "$work/install.log"

check "install exits 0" test -s "$work/install.log"
check "no ~/.local/bin/steam shim" missing "$XDG_BIN_HOME/steam"
check "steam-ember installed" present "$XDG_BIN_HOME/steam-ember"
check "steam-ember executable" test -x "$XDG_BIN_HOME/steam-ember"
check "wired entry installed" present "$XDG_DATA_HOME/applications/wired-steam.desktop"
check "wired entry is named Wired Steam" \
	file_has "$XDG_DATA_HOME/applications/wired-steam.desktop" '^Name=Wired Steam$'
check "wired entry runs steam-ember" \
	file_has "$XDG_DATA_HOME/applications/wired-steam.desktop" '^Exec=steam-ember %U$'
check "no user-level steam.desktop written" \
	missing "$XDG_DATA_HOME/applications/steam.desktop"
check "installer said Steam is untouched" \
	file_has "$work/install.log" "Steam's own launchers are untouched"
check "cloud-push timer installed, not enabled" \
	present "$XDG_CONFIG_HOME/systemd/user/ember-cloud-push.timer"
check "source install records its commit" \
	sh -c "grep -q '+source-' '$XDG_DATA_HOME/ember/VERSION'"

# The launcher must resolve the distributor's steam, not itself. The stub steam
# is FIRST on PATH so this can never reach the machine's real client.
"$XDG_BIN_HOME/steam-ember" --probe >/dev/null 2>&1 || true
check "steam-ember ran the real steam" present "$work/launched"
check "steam-ember passed LD_AUDIT" \
	sh -c "grep -q '^LD_AUDIT=.*ember-library-inject.so' '$work/launched'"
check "steam-ember forwarded argv" file_has "$work/launched" '^argv=--probe$'

# --- legacy install, then upgrade ------------------------------------------
printf '%s\n' '[Desktop Entry]' 'Name=Steam' 'Exec=steam-ember %U' 'X-Ember-Alternative=true' \
	> "$XDG_DATA_HOME/applications/steam.desktop"
printf '%s\n' '[Desktop Entry]' 'Name=Steam' 'Exec=steam %U' \
	> "$XDG_DATA_HOME/applications/steam.desktop.pre-ember"
printf '%s\n' '#!/bin/sh' '# generated by ember' 'exec steam-ember "$@"' \
	> "$XDG_BIN_HOME/steam"
chmod 755 "$XDG_BIN_HOME/steam"

run_install

check "upgrade removes the legacy shim" missing "$XDG_BIN_HOME/steam"
check "upgrade restores vanilla steam.desktop" \
	file_has "$XDG_DATA_HOME/applications/steam.desktop" '^Exec=steam %U$'
check "restored entry is no longer ember's" \
	sh -c "! grep -q X-Ember '$XDG_DATA_HOME/applications/steam.desktop'"
check "upgrade keeps steam-ember" present "$XDG_BIN_HOME/steam-ember"

# --- uninstall --------------------------------------------------------------
sh "$repo/scripts/install.sh" --uninstall \
	>"$work/uninstall.log" 2>&1

check "uninstall removes steam-ember" missing "$XDG_BIN_HOME/steam-ember"
check "uninstall removes the wired entry" \
	missing "$XDG_DATA_HOME/applications/wired-steam.desktop"
check "uninstall leaves vanilla steam.desktop alone" \
	file_has "$XDG_DATA_HOME/applications/steam.desktop" '^Exec=steam %U$'
check "uninstall leaves the system steam alone" present "$syst/steam"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
