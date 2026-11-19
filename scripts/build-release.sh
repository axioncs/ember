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
else
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	printf 'building ember-core (%s)\n' "${EMBER_CORE_REF:-ember}"
	git clone --depth 1 --branch "${EMBER_CORE_REF:-ember}" \
		"${EMBER_CORE_REPO:-https://github.com/axioncs/ember-core}" "$work/src"
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
