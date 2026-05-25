#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Pollen — installer
#  https://github.com/amalgame-lang/pollen
#
#  Compiles `pollen-node` from source via `amc` and drops the
#  binary + `pollen` dispatcher into <prefix>/bin.
#
#  Usage:
#    curl -sSL https://raw.githubusercontent.com/amalgame-lang/pollen/main/install.sh | bash
#    # or, from a local clone:
#    ./install.sh
#
#  Env vars:
#    POLLEN_VERSION  Git tag to install (default: latest GitHub release;
#                    "main" = current HEAD)
#    POLLEN_PREFIX   Install prefix (default: $HOME/.local)
#    AMC             Path to amc (default: looks on PATH)
# ═══════════════════════════════════════════════════════════

set -euo pipefail

REPO="amalgame-lang/pollen"
VERSION="${POLLEN_VERSION:-latest}"
PREFIX="${POLLEN_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/pollen"
AMC="${AMC:-}"

if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; NC=''
fi
say()  { echo -e "${GREEN}→${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1" >&2; }
die()  { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# ── Locate amc ─────────────────────────────────────
if [ -z "$AMC" ]; then
    if command -v amc >/dev/null 2>&1; then
        AMC="$(command -v amc)"
    else
        die "amc not found. Install Amalgame first: https://github.com/amalgame-lang/Amalgame"
    fi
fi
AMC_VERSION=$("$AMC" --version 2>&1 | head -1 | awk '{print $2}')
say "amc: $AMC ($AMC_VERSION)"

# Sanity check: pollen requires amc v0.8.52+ for UdpSocket.ReceiveFrom.
case "$AMC_VERSION" in
    0.0.*|0.1.*|0.2.*|0.3.*|0.4.*|0.5.*|0.6.*|0.7.*|0.8.0|0.8.1|0.8.2|0.8.3|0.8.4|0.8.5|0.8.6|0.8.7|0.8.8|0.8.9|0.8.[1-4]?|0.8.5[0-1])
        die "amc $AMC_VERSION too old; Pollen needs >= 0.8.52 (UdpSocket.ReceiveFrom)" ;;
esac

# ── Resolve sources ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || pwd)"
SRC_DIR=""

if [ -f "$SCRIPT_DIR/tools/pollen-node.am" ]; then
    SRC_DIR="$SCRIPT_DIR"
    say "Installing from local clone: $SRC_DIR"
else
    # Curl-pipe install — fetch from GitHub.
    TMP="$(mktemp -d -t pollen-inst-XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT
    if [ "$VERSION" = "latest" ]; then
        VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/' || echo "main")
        [ -z "$VERSION" ] && VERSION="main"
    fi
    say "Fetching $REPO@$VERSION"
    curl -fsSL "https://github.com/$REPO/archive/$VERSION.tar.gz" \
        | tar -xz -C "$TMP"
    SRC_DIR=$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -d "$SRC_DIR/tools" ] || die "downloaded archive missing tools/"
fi

# ── Compile pollen-node ────────────────────────────
say "Compiling pollen-node…"
BUILD_DIR="$(mktemp -d -t pollen-build-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Locate amc's runtime + stdlib facade dirs.
AMC_DIR="$(dirname "$AMC")"
if [ -d "$AMC_DIR/../share/amalgame/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/../share/amalgame/runtime"
    AMC_STDLIB="$AMC_DIR/../share/amalgame/stdlib"
elif [ -d "$AMC_DIR/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/runtime"
    AMC_STDLIB="$AMC_DIR/src/stdlib"
else
    die "cannot locate amc runtime/ headers (looked next to $AMC and ../share/amalgame/)"
fi
[ -f "$AMC_STDLIB/json.am" ] || die "cannot locate $AMC_STDLIB/json.am (Pollen needs JSON parsing)"

# Locate amalgame-datetime in the package cache. Pollen needs
# DateTime.NowNanos() for timestamps + retry deadlines (previous
# iterations shelled out to `date +%s%3N` which was 1-3 ms per
# call, too expensive once Phase 1.4 retry budgets came in).
DT_CACHE_BASE="$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-datetime"
if [ ! -d "$DT_CACHE_BASE" ]; then
    die "amalgame-datetime not installed in the package cache. Run \`amc package add datetime\` first."
fi
DT_VER=$(ls -1 "$DT_CACHE_BASE" 2>/dev/null | sort -V | tail -1)
[ -n "$DT_VER" ] || die "amalgame-datetime cache empty"
DT_FACADE="$DT_CACHE_BASE/$DT_VER/facade.am"
DT_LIB="$DT_CACHE_BASE/$DT_VER/build/linux-x86_64/libamalgame-pkg-DateTime.a"
[ -f "$DT_FACADE" ] || die "datetime facade.am missing at $DT_FACADE"
[ -f "$DT_LIB" ]    || die "datetime build archive missing at $DT_LIB — try \`amc package add datetime\` again"

# amalgame-random — used by pollen-client for RFC 4122 v4 UUIDs.
# Crypto-grade SystemBytes(16) + version/variant bit fix gives a
# TARMeule-compatible messageId without per-call shell-outs.
RND_CACHE_BASE="$HOME/.amalgame/packages/github.com/amalgame-lang/amalgame-random"
if [ ! -d "$RND_CACHE_BASE" ]; then
    die "amalgame-random not installed in the package cache. Run \`amc package add random\` first."
fi
RND_VER=$(ls -1 "$RND_CACHE_BASE" 2>/dev/null | sort -V | tail -1)
[ -n "$RND_VER" ] || die "amalgame-random cache empty"
RND_FACADE="$RND_CACHE_BASE/$RND_VER/facade.am"
RND_LIB="$RND_CACHE_BASE/$RND_VER/build/linux-x86_64/libamalgame-pkg-Random.a"
[ -f "$RND_FACADE" ] || die "random facade.am missing at $RND_FACADE"
[ -f "$RND_LIB" ]    || die "random build archive missing at $RND_LIB — try \`amc package add random\` again"

# Compile pollen-node.am with json.am + datetime facade as extra
# sources so JsonParser / DateTime class methods resolve.
(cd "$BUILD_DIR" && "$AMC" -o pollen-node \
    "$SRC_DIR/tools/pollen-node.am" \
    "$AMC_STDLIB/json.am" \
    "$DT_FACADE" \
    --quiet)
[ -f "$BUILD_DIR/pollen-node.c" ] || die "amc didn't produce pollen-node.c"

# Cached packages' runtime/ — amc auto-injects #include lines for
# net-http into the generated .c regardless of imports (known v0.8.51
# filter quirk, tracked in amc resolver-refactor follow-up); this
# loop adds -I flags so gcc resolves the transitive headers.
PKG_INCS=""
for d in "$HOME"/.amalgame/packages/github.com/amalgame-lang/*/; do
    [ -d "$d" ] || continue
    latest=$(ls -1 "$d" 2>/dev/null | sort -V | tail -1)
    [ -n "$latest" ] && PKG_INCS="$PKG_INCS -I$d$latest/runtime"
done

# datetime's `@c {}` blocks live in facade.am; amc emits forward
# decls in the generated .c but not the bodies, so we link against
# the precompiled libamalgame-pkg-DateTime.a archive that ships in
# the package cache.
gcc -O2 -I"$AMC_RUNTIME" $PKG_INCS "$BUILD_DIR/pollen-node.c" \
    "$DT_LIB" -lgc -lm -lz -ldl -lpthread \
    -o "$BUILD_DIR/pollen-node-bin" \
    || die "gcc link failed (pollen-node)"

# Compile pollen-client (one-shot UDP send, drops nc -u dep).
say "Compiling pollen-client…"
(cd "$BUILD_DIR" && "$AMC" -o pollen-client \
    "$SRC_DIR/tools/pollen-client.am" \
    "$AMC_STDLIB/json.am" \
    "$DT_FACADE" \
    "$RND_FACADE" \
    --quiet)
[ -f "$BUILD_DIR/pollen-client.c" ] || die "amc didn't produce pollen-client.c"

gcc -O2 -I"$AMC_RUNTIME" $PKG_INCS "$BUILD_DIR/pollen-client.c" \
    "$DT_LIB" "$RND_LIB" -lgc -lm -lz -ldl -lpthread \
    -o "$BUILD_DIR/pollen-client-bin" \
    || die "gcc link failed (pollen-client)"

# ── Install ────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SHARE_DIR/bin"
cp "$BUILD_DIR/pollen-node-bin"   "$SHARE_DIR/bin/pollen-node"
cp "$BUILD_DIR/pollen-client-bin" "$SHARE_DIR/bin/pollen-client"
cp "$SRC_DIR/tools/pollen"        "$BIN_DIR/pollen"
chmod +x "$BIN_DIR/pollen" "$SHARE_DIR/bin/pollen-node" "$SHARE_DIR/bin/pollen-client"

say "Installed:"
echo "    $BIN_DIR/pollen"
echo "    $SHARE_DIR/bin/pollen-node"
echo "    $SHARE_DIR/bin/pollen-client"
echo ""

case ":$PATH:" in
    *":$BIN_DIR:"*) say "$BIN_DIR is on PATH — try \`pollen version\`" ;;
    *) warn "$BIN_DIR is NOT on PATH. Add it to your shell rc:"
       echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
