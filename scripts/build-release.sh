#!/bin/sh
# Builds the release artifact: ember-core compiled against a low glibc floor,
# packaged with the CLI and the version file.
#
#   sh scripts/build-release.sh v0.2.0
#
# Run it in a container whose glibc is older than the oldest target distribution
# (CI uses debian:bookworm, glibc 2.36); building on a rolling distro bakes its
# glibc in and the artifact then refuses to load on everything older.
#
# EMBER_CORE_REF  ember-core branch or tag to build (default: ember).
# EMBER_CORE_BIN  package an existing ember-core.so instead of building.

set -eu

tag="${1:-}"
[ -n "$tag" ] || { printf 'usage: build-release.sh <tag>\n' >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
stage="$dist/stage"
out="ember-$tag-x86_64-linux.tar.gz"

rm -rf "$dist"
mkdir -p "$stage"

if [ -n "${EMBER_CORE_BIN:-}" ]; then
	printf 'packaging %s\n' "$EMBER_CORE_BIN"
	install -m755 "$EMBER_CORE_BIN" "$stage/ember-core.so"
	# The installer and its libs come from the same core checkout. Without this
	# the archive has a payload but nothing to install it with.
	if [ -z "${EMBER_CORE_SRC:-}" ] && [ -d "${EMBER_CORE_DIR:-}" ]; then
		EMBER_CORE_SRC="$EMBER_CORE_DIR"
	fi
	export EMBER_CORE_SRC
else
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	printf 'building ember-core (%s)\n' "${EMBER_CORE_REF:-ember}"
	git clone --depth 1 --branch "${EMBER_CORE_REF:-ember}" \
		"${EMBER_CORE_REPO:-https://github.com/axioncs/ember-core}" "$work/src"
	# The installer ships from the clone regardless of which binary is packaged.
	EMBER_CORE_SRC="$work/src"
	export EMBER_CORE_SRC
	make -C "$work/src" -j"$(nproc)" bin/ember-core.so bin/ember-library-inject.so
	install -m755 "$work/src/bin/ember-core.so" "$stage/ember-core.so"
	install -m755 "$work/src/bin/ember-library-inject.so" \
		"$stage/ember-library-inject.so"

	# SteamStub. The core looks for its helper under tools/ relative to the
	# library, so the script and the bundled Steamless binaries ship here.
	# Without them DRM-protected titles fail with "Application load error 6".
	mkdir -p "$stage/tools/steamstub-bypass"
	install -m755 "$work/src/tools/steamstub-bypass/"*.sh \
		"$stage/tools/steamstub-bypass/"
	cp -a "$work/src/tools/steamless-bin" "$stage/tools/steamless-bin"
fi

if [ -d "${EMBER_STEAMSTUB_DIR:-}" ]; then
	mkdir -p "$stage/tools/steamstub-bypass"
	install -m755 "$EMBER_STEAMSTUB_DIR/"*.sh "$stage/tools/steamstub-bypass/"
fi

install -m644 "$root/packages/cli/ember.lua" "$stage/ember.lua"
printf '%s\n' "$tag" > "$stage/VERSION"

# The distro installer and the shell libraries it sources. These live in
# ember-core, not this repo, so they are taken from the same clone the core
# binary came from. Without them the tarball carries a payload but cannot
# install itself: setup.sh copies these into ~/.local/share/ember, and the
# unit library among them is what renders the badge watcher and cloud-push
# timer.
installer_src="${EMBER_CORE_SRC:-}"
if [ -n "$installer_src" ] && [ -f "$installer_src/setup.sh" ]; then
	install -m755 "$installer_src/setup.sh" "$stage/setup.sh"
	mkdir -p "$stage/tools"
	for lib in desktop-coverage.lib.sh launcher-shim.lib.sh \
	           desktop-guardian-units.lib.sh ember-units.lib.sh
	do
		if [ -f "$installer_src/tools/$lib" ]; then
			install -m644 "$installer_src/tools/$lib" "$stage/tools/$lib"
		fi
	done
	if [ -f "$installer_src/tools/ember-autoupdate.sh" ]; then
		install -m755 "$installer_src/tools/ember-autoupdate.sh" \
			"$stage/tools/ember-autoupdate.sh"
	fi
	if [ -f "$installer_src/ensure-desktop-coverage.sh" ]; then
		install -m755 "$installer_src/ensure-desktop-coverage.sh" \
			"$stage/ensure-desktop-coverage.sh"
	fi
else
	printf 'warning: no ember-core checkout; the archive will carry no installer\n' >&2
fi

# The DevTools client and the badge script the UI layer needs at runtime. The
# core rewrites the webhelper's own exec arguments, so no preload shim ships.
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -o "$stage/ember-cdpd" "$root/packages/cdp/ember-cdpd.c"
install -m644 "$root/packages/cdp/badge.js" "$stage/badge.js"

# Deterministic archive: mtimes, uid/gid, order and gzip header are all fixed,
# so rebuilding the same source tree yields the same bytes. Without this the
# sha256 of the artifact changes on every rebuild, and a tag that is re-pushed
# to pick up a fix silently invalidates the hash a consumer pinned.
export LC_ALL=C
export TZ=UTC
find "$stage" -exec touch -h -d '@0' {} +
export GZIP=-n

tar --sort=name \
    --mtime='@0' \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "$stage" . | gzip -n -9 > "$dist/$out"
(cd "$dist" && sha256sum "$out" > "$out.sha256")

printf '%s\n' "$dist/$out"
