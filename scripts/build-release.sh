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
	make -C "$work/src" -j"$(nproc)" audit-libs
	install -m755 "$work/src/bin/SLSsteam.so" "$stage/ember-core.so"
fi

install -m644 "$root/packages/cli/ember.lua" "$stage/ember.lua"
printf '%s\n' "$tag" > "$stage/VERSION"

# The preload shim ships with the artifact so the script install never needs a
# compiler: it interposes exec* for the webhelper only.
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -shared -fPIC -o "$stage/ember-cef.so" \
	"$root/packages/cefshim/ember-cef.c" -ldl

# The DevTools client and the badge script the UI layer needs at runtime.
${CC:-cc} -std=gnu11 -O2 -Wall -Wextra -o "$stage/ember-cdpd" "$root/packages/cdp/ember-cdpd.c"
install -m644 "$root/packages/cdp/badge.js" "$stage/badge.js"

tar czf "$dist/$out" -C "$stage" .
(cd "$dist" && sha256sum "$out" > "$out.sha256")

printf '%s\n' "$dist/$out"
