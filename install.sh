#!/usr/bin/env bash
#
# Install animepahe-dl into ~/.local/bin
# Works on Linux and macOS. Only needs curl.
#
# Usage:
#   ./install.sh
#   ./install.sh [url] [destination]
#   curl -fsSL https://raw.githubusercontent.com/ruxartic/animepahe-dl/master/install.sh | bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_URL="https://raw.githubusercontent.com/ruxartic/animepahe-dl/master/animepahe-dl.sh"
URL="${ANIMEPAHE_INSTALL_URL:-$DEFAULT_URL}"
BIN="${ANIMEPAHE_INSTALL_BIN:-}"
CONFIG_DIR=""
CONFIG_FILE=""
SHA256=""
WANT_CONFIG=1
UNINSTALL=0
FORCE=0
URL_SET=0
BIN_SET=0
TMP=""

# ---------------------------------------------------------------------------
# UI — same language as animepahe-dl itself
# ---------------------------------------------------------------------------
BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
S_OK="✔"; S_ERR="✘"; S_WARN="▲"; S_INFO="•"; S_RUN="›"; S_SKIP="↷"
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m'
    YELLOW=$'\033[33m' BLUE=$'\033[34m' CYAN=$'\033[36m' NC=$'\033[0m'
fi
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" != [Uu][Tt][Ff]* ]]; then
    S_OK="+"; S_ERR="x"; S_WARN="!"; S_INFO="*"; S_RUN=">"; S_SKIP="-"
fi
IND="  "

row() { # kind label [detail]
    local kind=$1 label=$2 detail=${3:-} sym col
    case $kind in
        ok)   sym=$S_OK;   col=$GREEN ;;
        warn) sym=$S_WARN; col=$YELLOW ;;
        err)  sym=$S_ERR;  col=$RED ;;
        run)  sym=$S_RUN;  col=$CYAN ;;
        skip) sym=$S_SKIP; col=$DIM ;;
        *)    sym=$S_INFO; col=$BLUE ;;
    esac
    printf '%s%s%s%s %s%-11s%s %s\n' "$IND" "$col" "$sym" "$NC" "$BOLD" "$label" "$NC" "$detail"
}
note() { printf '%s%s%s\n' "$IND" "$DIM" "$*"; }
err_msg() { printf '%s%s%s %s%s\n' "$IND" "$RED" "$S_ERR" "$NC" "$*" >&2; }
err()  { err_msg "$*"; exit 1; }

banner() {
    printf '\n%s%sanimepahe-dl%s %sinstaller%s\n\n' "$BOLD" "$CYAN" "$NC" "$DIM" "$NC"
}

cleanup() {
    if [[ -n "$TMP" && -f "$TMP" ]]; then rm -f "$TMP"; fi
    return 0
}
trap cleanup EXIT

usage() {
    cat <<EOF
${BOLD}animepahe-dl installer${NC}

${BOLD}Usage${NC}
  install.sh [url] [destination]
  install.sh [options]

${BOLD}Options${NC}
  -u, --url <url>      script to install (default: the master copy on GitHub)
  -d, --dest <path>    install path (default: ~/.local/bin/anime)
      --sha256 <hash>  verify the download against this SHA-256 checksum
      --no-config      don't create a sample config file
      --force          overwrite the destination without keeping a backup
      --uninstall      remove an installed copy
  -h, --help           show this help

${BOLD}Environment${NC}
  ANIMEPAHE_INSTALL_URL   default for --url
  ANIMEPAHE_INSTALL_BIN   default for --dest
  NO_COLOR               plain output
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
positional=()
while (( $# )); do
    case $1 in
        -h|--help)   usage; exit 0 ;;
        -u|--url)    [[ $# -ge 2 ]] || err "--url needs a value."; URL=$2; URL_SET=1; shift ;;
        --url=*)     URL=${1#*=}; URL_SET=1 ;;
        -d|--dest)   [[ $# -ge 2 ]] || err "--dest needs a value."; BIN=$2; BIN_SET=1; shift ;;
        --dest=*)    BIN=${1#*=}; BIN_SET=1 ;;
        --sha256)    [[ $# -ge 2 ]] || err "--sha256 needs a value."; SHA256=$2; shift ;;
        --sha256=*)  SHA256=${1#*=} ;;
        --no-config) WANT_CONFIG=0 ;;
        --force)     FORCE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --)          shift; positional+=("$@"); break ;;
        -*)          err "Unknown option: $1 (see --help)" ;;
        *)           positional+=("$1") ;;
    esac
    shift
done
# Positional form stays supported: install.sh [url] [destination]
# An explicit --url/--dest wins over the positional form.
if (( URL_SET == 0 )) && (( ${#positional[@]} >= 1 )); then URL=${positional[0]}; fi
if (( BIN_SET == 0 )) && (( ${#positional[@]} >= 2 )); then BIN=${positional[1]}; fi

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
[[ -n "${HOME:-}" ]] || err "HOME is not set — cannot work out where to install."
if [[ -z "$BIN" ]]; then
    BIN="$HOME/.local/bin/anime"
elif [[ "$BIN" != /* ]]; then
    BIN="$PWD/$BIN"
fi
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/animepahe-dl"
CONFIG_FILE="$CONFIG_DIR/config.env"

command -v curl >/dev/null 2>&1 || err "curl is required, but it was not found."

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sha256_of() { # file → checksum (empty when no tool is available)
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf ''
    fi
}

version_of() { # file → version string (empty when not found)
    local v=""
    v=$(grep -m1 -oE 'VERSION="[^"]+"' "$1" 2>/dev/null \
        | head -n1 | sed -E 's/^VERSION="([^"]+)"$/\1/') || v=""
    printf '%s' "$v"
}

same_file() { # a b → true when both files have the same content
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2"
    else
        [[ "$(sha256_of "$1")" == "$(sha256_of "$2")" ]]
    fi
}

install_file() { # src dest mode
    local src=$1 dest=$2 mode=$3
    if command -v install >/dev/null 2>&1; then
        install -m "$mode" "$src" "$dest"
    else
        cp -f "$src" "$dest" && chmod "$mode" "$dest"
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if (( UNINSTALL )); then
    banner
    if [[ -f "$BIN" ]]; then
        rm -f "$BIN"
        row ok "Removed" "$BIN"
    else
        row skip "Not installed" "$BIN"
    fi
    note "the config file was left alone: $CONFIG_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
banner
row info "Source" "$URL"
row info "Target" "$BIN"

# 1. Fetch — local file, or https only
TMP=$(mktemp) || err "could not create a temporary file."
if [[ -f "$URL" ]]; then
    cp -f "$URL" "$TMP" || err "could not read $URL."
    row run "Reading" "local file"
elif [[ "$URL" == http://* ]]; then
    err "refusing to install over plain HTTP: $URL"
else
    row run "Downloading" "…"
    code=""
    if ! code=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 \
            --connect-timeout 15 --max-time 120 -w '%{http_code}' "$URL" -o "$TMP" 2>/dev/null); then
        case "${code:-000}" in
            404)
                err_msg "not found: $URL — the repository may be private or renamed."
                note "install from a checkout instead: ./install.sh ./animepahe-dl.sh"
                exit 1 ;;
            000) err "could not reach $URL — network error." ;;
            *)   err "download failed (HTTP ${code:-?}): $URL" ;;
        esac
    fi
    row ok "Downloaded" "$(du -h "$TMP" 2>/dev/null | cut -f1 || echo '?')"
fi

# 2. Sanity check the payload
[[ -s "$TMP" ]] || err "the downloaded file is empty."
head -c 64 "$TMP" | grep -q '^#!' || err "the downloaded file is not a script (no shebang)."
grep -qi 'animepahe' "$TMP" || row warn "Check" "the file does not mention animepahe."
# A truncated download would show up as a syntax error (bash 4+ only, so that
# the installer still runs on the bash 3.2 that macOS ships).
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    "${BASH:-bash}" -n "$TMP" 2>/dev/null || err "the downloaded script has a syntax error."
    row ok "Checked" "the script parses"
fi

# 3. Integrity check
if [[ -n "$SHA256" ]]; then
    sum=$(sha256_of "$TMP")
    [[ -n "$sum" ]] || err "--sha256 needs sha256sum or shasum on this system."
    want=$(printf '%s' "$SHA256" | tr 'A-Z' 'a-z')
    got=$(printf '%s' "$sum" | tr 'A-Z' 'a-z')
    if [[ "$want" != "$got" ]]; then
        err "checksum mismatch: expected $SHA256, got $sum"
    fi
    row ok "Verified" "sha256 ${sum:0:16}…"
fi

VERSION=$(version_of "$TMP")
if [[ -n "$VERSION" ]]; then
    row ok "Version" "animepahe-dl v$VERSION"
else
    row warn "Version" "no version string found in the script"
fi

# 4. Install (back up an existing copy instead of dropping it)
mkdir -p "$(dirname "$BIN")" 2>/dev/null || err "cannot create $(dirname "$BIN")."
if [[ -d "$BIN" ]]; then err "the destination is a directory: $BIN"; fi
if [[ -f "$BIN" ]]; then
    if same_file "$TMP" "$BIN"; then
        row skip "Unchanged" "$BIN is already up to date"
    else
        if (( FORCE )); then
            row skip "Backup" "not kept (--force)"
        else
            cp -p "$BIN" "$BIN.bak" 2>/dev/null || true
            row skip "Backup" "$BIN.bak"
        fi
        install_file "$TMP" "$BIN" 755 || err "could not write $BIN."
        row ok "Installed" "$BIN${VERSION:+ (v$VERSION)}"
    fi
else
    install_file "$TMP" "$BIN" 755 || err "could not write $BIN."
    row ok "Installed" "$BIN${VERSION:+ (v$VERSION)}"
fi

# 5. Sample config — never overwrite an existing one
if (( WANT_CONFIG )); then
    if [[ -f "$CONFIG_FILE" ]]; then
        row skip "Config" "kept $CONFIG_FILE"
    else
        mkdir -p "$CONFIG_DIR" 2>/dev/null || err "cannot create $CONFIG_DIR."
        chmod 700 "$CONFIG_DIR" 2>/dev/null || true
        cat >"$CONFIG_FILE" <<'EOF' || err "cannot write $CONFIG_FILE."
# AnimePahe Downloader configuration
#
# Paste your Cloudflare clearance cookie from the browser devtools:
#   ANIMEPAHE_CF=cf_clearance=xxxx...
# Or export it instead: export ANIMEPAHE_CF=...
ANIMEPAHE_CF=

# Browser User-Agent sent with every request (default: Chrome/Windows)
# ANIMEPAHE_UA=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36

# Download root (default: ~/Videos)
# ANIMEPAHE_VIDEO_DIR=$HOME/Videos
EOF
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        row ok "Config" "$CONFIG_FILE (mode 600)"
    fi
fi

# 6. Next steps
printf '\n'
bindir=$(dirname "$BIN")
if [[ ":$PATH:" != *":$bindir:"* ]]; then
    row warn "PATH" "$bindir is not in your PATH"
    if [[ "$bindir" == "$HOME"/* ]]; then
        note "add it with: export PATH=\"\$HOME/${bindir#"$HOME"/}:\$PATH\""
    else
        note "add it with: export PATH=\"$bindir:\$PATH\""
    fi
fi
row info "Run" "$(basename "$BIN") -h"
note "if the site answers with HTTP 403, run \"$(basename "$BIN") --login\" once"
if [[ -f "$CONFIG_FILE" ]]; then note "edit: $CONFIG_FILE"; fi
printf '\n'
