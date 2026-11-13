#!/bin/sh
# Proves the preload shim rewrites only the webhelper's argv.
#
#   sh tools/test_cefshim.sh [path/to/ember-cef.so]
#
# Runs a fake steamwebhelper under LD_PRELOAD and checks the flags it received,
# on a throwaway HOME so the published contract file can be inspected too.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
so="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -z "$so" ]; then
	so="$work/ember-cef.so"
	cc -O2 -shared -fPIC -o "$so" "$root/packages/cefshim/ember-cef.c" -ldl
fi

mkdir -p "$work/home" "$work/bin"
cat > "$work/bin/steamwebhelper" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGS_OUT"
EOF
chmod +x "$work/bin/steamwebhelper"

cat > "$work/bin/notahelper" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGS_OUT"
EOF
chmod +x "$work/bin/notahelper"

fail=0
check() {
	if grep -qx -- "$2" "$ARGS_OUT"; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s (no %s)\n' "$1" "$2" >&2
		fail=1
	fi
}
absent() {
	if grep -q -- "$2" "$ARGS_OUT"; then
		printf 'FAIL %s (%s should not be there)\n' "$1" "$2" >&2
		fail=1
	else
		printf 'ok   %s\n' "$1"
	fi
}

ARGS_OUT="$work/args1"; export ARGS_OUT
# The interposer must be loaded in the process that *does* the exec, so the
# spawner is a fresh shell started with LD_PRELOAD; setting it on the child
# alone would prove nothing.
PATH="$work/bin:$PATH" HOME="$work/home" EMBER_CEF_PORT=9222 LD_PRELOAD="$so" \
	sh -c 'exec steamwebhelper --type=utility' >/dev/null 2>&1 || true
check "webhelper keeps its own args" "--type=utility"
check "webhelper gets the port" "--remote-debugging-port=9222"
check "webhelper gets the address" "--remote-debugging-address=127.0.0.1"

ARGS_OUT="$work/args2"; export ARGS_OUT
PATH="$work/bin:$PATH" HOME="$work/home" LD_PRELOAD="$so" \
	sh -c 'exec notahelper --type=utility' >/dev/null 2>&1 || true
absent "other children untouched" "--remote-debugging-port"

if [ -f "$work/home/.config/ember/cef_port" ]; then
	port="$(sed -n '1p' "$work/home/.config/ember/cef_port")"
	owner="$(sed -n '2p' "$work/home/.config/ember/cef_port")"
	if [ "$port" = "9222" ] && printf '%s' "$owner" | grep -q '^owner [0-9]\+ [0-9]\+$'; then
		printf 'ok   contract file: %s / %s\n' "$port" "$owner"
	else
		printf 'FAIL contract file: %s / %s\n' "$port" "$owner" >&2
		fail=1
	fi
else
	printf 'FAIL contract file was not written\n' >&2
	fail=1
fi

[ "$fail" = 0 ] || exit 1
printf 'all cef shim tests passed\n'
