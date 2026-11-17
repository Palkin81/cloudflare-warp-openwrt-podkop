#!/bin/sh
# How warp-podkop activates the new cfwarp section: through the Apply of Podkop PE when the
# installed Podkop has one (its reload keeps the admitted runtime and returns 1), through the
# plain reload of stock Podkop otherwise. Runs the activation functions of warp-podkop against
# mock Podkop binaries; the attach checks themselves need a router (tests/router-integration.sh).

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /tmp/warp-podkop-test.XXXXXX)
trap 'rm -rf "$work"' EXIT

# jsonfilter as on OpenWrt: reads stdin, prints booleans in lower case, exits 1 on no match
cat >"$work/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json, sys
expr = sys.argv[sys.argv.index("-e") + 1]
try:
    value = json.loads(sys.stdin.read() or "null")
    for part in expr[2:].split("."):
        value = value[part]
except Exception:
    sys.exit(1)
print(str(value).lower() if isinstance(value, bool) else value)
EOF
chmod 755 "$work/jsonfilter"
PATH="$work:$PATH"
export PATH

# the functions block of warp-podkop, without the attach steps around it
sed -n '/^podkop_bin=/,/^warp_podkop_acquire/p' "$root_dir/root/usr/libexec/warp-podkop" | sed '$d' >"$work/functions.sh"
grep -q '^podkop_activate()' "$work/functions.sh"

# Podkop PE mock: answers service_busy $BUSY times, then starts; the status says running once,
# then $FINAL. Calls are recorded.
cat >"$work/podkop-pe" <<'EOF'
#!/bin/sh
# the two functions warp-podkop looks for, at column 0 as in the real Podkop PE script
subscription_config_apply_start() { :; }
subscription_config_apply_status() { :; }
calls="$MOCK_DIR/calls"; echo "$1" >>"$calls"
case "$1" in
subscription_config_apply_start)
    n=$(grep -c '^subscription_config_apply_start$' "$calls")
    if [ "$n" -le "${BUSY:-0}" ]; then echo '{"success":false,"error":"service_busy"}'; exit 1; fi
    echo '{"success":true,"started":true}' ;;
subscription_config_apply_status)
    n=$(grep -c '^subscription_config_apply_status$' "$calls")
    if [ "$n" -le 1 ]; then echo '{"success":true,"state":"running"}'; else echo "{\"success\":true,\"state\":\"${FINAL:-done}\"}"; fi ;;
reload) exit 1 ;;
esac
EOF
chmod 755 "$work/podkop-pe"

cat >"$work/podkop-stock" <<'EOF'
#!/bin/sh
echo "$1" >>"$MOCK_DIR/calls"
[ "$1" = reload ]
EOF
chmod 755 "$work/podkop-stock"

run() { # mock, BUSY, FINAL -> exit code of podkop_activate
    rm -f "$work/calls"; : >"$work/calls"
    (
        MOCK_DIR=$work BUSY=$2 FINAL=$3 WARP_PODKOP_BIN="$work/$1"
        export MOCK_DIR BUSY FINAL WARP_PODKOP_BIN
        sleep() { :; }
        warp_podkop_release() { echo release >>"$MOCK_DIR/calls"; }
        . "$work/functions.sh"
        podkop_activate
    )
}

# PE: applied through Apply, never through reload, after giving back the shared Podkop lock
run podkop-pe 0 done
grep -q '^subscription_config_apply_start$' "$work/calls"
[ "$(sed -n 1p "$work/calls")" = release ] || { echo 'Podkop lock still held when the Apply started' >&2; exit 1; }
if grep -q '^reload$' "$work/calls"; then echo 'PE path used reload' >&2; exit 1; fi

# PE busy twice, then applied
run podkop-pe 2 done
[ "$(grep -c '^subscription_config_apply_start$' "$work/calls")" = 3 ]

# PE Apply failed: attach must fail (and roll back)
if run podkop-pe 0 failed; then echo 'failed Apply reported as success' >&2; exit 1; fi

# PE always busy: gives up after its bounded wait
if run podkop-pe 99 done; then echo 'endless busy reported as success' >&2; exit 1; fi

# stock Podkop: the plain reload, as before
run podkop-stock 0 done
grep -q '^reload$' "$work/calls"
if grep -q 'subscription_config_apply' "$work/calls"; then echo 'stock path used the PE Apply' >&2; exit 1; fi

printf '%s\n' 'Podkop attach activation tests: OK'
