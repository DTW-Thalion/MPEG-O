#!/usr/bin/env bash
# check-deps.sh — verify build prerequisites for the MPEG-O Objective-C
# reference implementation before invoking `make`.
#
# Exit codes:
#   0  all required dependencies present
#   1  one or more required dependencies missing

set -u

missing=0
warn=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; missing=$((missing+1)); }
note() { printf '  [warn] %s\n' "$*"; warn=$((warn+1)); }

echo "==> MPEG-O dependency check"

# --- GNUstep make ----------------------------------------------------------
if command -v gnustep-config >/dev/null 2>&1; then
    GNUSTEP_MAKEFILES="$(gnustep-config --variable=GNUSTEP_MAKEFILES)"
    if [ -f "$GNUSTEP_MAKEFILES/GNUstep.sh" ]; then
        ok "gnustep-make ($GNUSTEP_MAKEFILES)"
    else
        fail "gnustep-make: GNUstep.sh not found under $GNUSTEP_MAKEFILES"
    fi
else
    fail "gnustep-config not on PATH (install gnustep-make)"
fi

# --- gnustep-base ----------------------------------------------------------
gs_base=""
gs_runtime=""
for cand in /usr/local/lib/libgnustep-base.so \
            /usr/lib/x86_64-linux-gnu/libgnustep-base.so \
            /usr/lib/libgnustep-base.so; do
    if [ -f "$cand" ]; then gs_base="$cand"; break; fi
done
if [ -n "$gs_base" ]; then
    ok "gnustep-base ($gs_base)"
    if command -v nm >/dev/null 2>&1; then
        if nm -D "$gs_base" 2>/dev/null | grep -q '\._OBJC_CLASS_NSObject$'; then
            gs_runtime="gnustep-2.0"
            say "       runtime ABI: gnustep-2.0 (non-fragile)"
        else
            gs_runtime="gnustep-1.8"
            say "       runtime ABI: gnustep-1.8 (fragile)"
        fi
    fi
else
    fail "libgnustep-base.so not found (install libgnustep-base-dev or build from source)"
fi

# --- Blocks support --------------------------------------------------------
# On gnustep-2.0 / libobjc2, blocks are fully supported and the preamble
# enables -fblocks. On gnustep-1.8 / GCC's libobjc, clang's -fblocks triggers
# GSVersionMacros.h to include <objc/blocks_runtime.h>, which libobjc does
# not ship — so the preamble DROPS -fblocks on that path. This is a soft
# capability note, not a build blocker.
if [ "$gs_runtime" = "gnustep-2.0" ]; then
    if [ -f /usr/include/objc/blocks_runtime.h ] || \
       [ -f /usr/local/include/objc/blocks_runtime.h ]; then
        ok "blocks support (objc/blocks_runtime.h present)"
    else
        note "objc/blocks_runtime.h missing despite gnustep-2.0 runtime — unusual libobjc2 layout"
    fi
else
    say "       blocks: disabled on gnustep-1.8 (preamble drops -fblocks)"
fi

# --- Objective-C compiler with ARC ----------------------------------------
objc_cc=""
if command -v clang >/dev/null 2>&1; then
    objc_cc="clang"
    ok "clang ($(clang --version | head -n1))"
else
    note "clang not found — gcc/gobjc cannot compile this project (no -fobjc-arc)"
fi

# --- HDF5 ------------------------------------------------------------------
hdf5_hdr=""
for cand in /usr/include/hdf5.h \
            /usr/include/hdf5/serial/hdf5.h \
            /usr/local/include/hdf5.h; do
    if [ -f "$cand" ]; then hdf5_hdr="$cand"; break; fi
done
if [ -n "$hdf5_hdr" ]; then
    ok "libhdf5 headers ($hdf5_hdr)"
else
    fail "libhdf5 headers not found (install libhdf5-dev)"
fi

# --- zlib ------------------------------------------------------------------
if [ -f /usr/include/zlib.h ] || [ -f /usr/local/include/zlib.h ]; then
    ok "zlib headers"
else
    fail "zlib.h not found (install zlib1g-dev)"
fi

# --- OpenSSL (Milestone 7, optional today) ---------------------------------
if [ -f /usr/include/openssl/ssl.h ] || [ -f /usr/local/include/openssl/ssl.h ]; then
    ok "openssl headers"
else
    note "openssl headers not found — required for Milestone 7 (install libssl-dev)"
fi

echo
if [ $missing -gt 0 ]; then
    echo "==> $missing required dependency(ies) missing. See above."
    exit 1
fi
if [ $warn -gt 0 ]; then
    echo "==> All required dependencies present ($warn optional warning(s))."
else
    echo "==> All dependencies present."
fi
exit 0
