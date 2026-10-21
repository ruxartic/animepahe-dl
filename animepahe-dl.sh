#!/usr/bin/env bash
#
# animepahe-dl — download anime from animepahe, right from your terminal.
#
#/ Usage:
#/   animepahe-dl.sh [options]
#/
#/ What to download:
#/   -a <name>              search for an anime by name
#/   -s <slug>              anime slug/uuid (ignored when -a is given)
#/   -e <selection>         episodes to download. Examples:
#/                            1              a single episode
#/                            1,3,5          several episodes
#/                            1-5            a range
#/                            *              everything
#/                            *,!1,!10-12    everything except 1 and 10-12
#/                            L3  /  F5      latest 3  /  first 5
#/                            10-  /  -5     from 10 onwards  /  up to 5
#/                            1-10,!5,L2     combine freely
#/   -r <resolution>        e.g. 1080, 720 (default: best available)
#/   -o <language>          audio language, e.g. eng, jpn. Default: English if the
#/                          episode offers it (even at a lower resolution than the
#/                          Japanese track), otherwise the best available. An explicit
#/                          -o only accepts that language; -r wins over the soft default.
#/
#/ Behaviour:
#/   -t <num>               parallel download threads (default: 4)
#/   -T <secs>              per-segment download timeout (default: 300)
#/   -l                     only print the m3u8 playlist URL(s), no download
#/   -y, --headless         never prompt: auto-pick the first search result and
#/                          fail if something required is missing
#/   --no-resume            ignore partial downloads and start from scratch
#/   --keep-workdir         keep per-episode work files after success
#/   --refresh              ignore cached lists and fetch the anime list and the
#/                          episode list fresh (they are cached otherwise)
#/   --ytdlp                download the video with yt-dlp instead of the built-in
#/                          downloader (it is also tried automatically if the
#/                          built-in one is refused by the stream host)
#/   --js-runtime <name>    JS runtime for stream deobfuscation: node (default),
#/                          bun, deno, or a path
#/   --login                open a temporary browser window and wait until the
#/                          site has really loaded (passing any Cloudflare check),
#/                          then save the cookie + User-Agent. If curl is still
#/                          refused (the site fingerprints it), requests to the
#/                          site are sent through that browser instead. Alone it
#/                          just logs in; with -a/-s it continues. Also offered
#/                          automatically when the site blocks a request.
#/   --no-color             disable colors (also honours NO_COLOR)
#/   -d                     debug output (cookie is never printed)
#/   -h, --help             show this help
#/   --version              show version
#/
#/ Environment (can also go in ~/.config/animepahe-dl/config.env as KEY=VALUE):
#/   ANIMEPAHE_CF                   Cloudflare cookie from your browser (devtools)
#/   ANIMEPAHE_HOST                 site URL (default https://animepahe.pw)
#/   ANIMEPAHE_UA                   User-Agent override
#/   ANIMEPAHE_VIDEO_DIR            download directory (default ~/Videos)
#/   ANIMEPAHE_LIST_FILE            cached master anime list
#/   ANIMEPAHE_LIST_CACHE_DAYS      how long the anime list is trusted (default 7)
#/   ANIMEPAHE_EPISODE_CACHE_HOURS  how long an episode list is trusted (default 6;
#/                                  0 = always fetch). Asking for an episode the cache
#/                                  doesn't know triggers a refresh automatically.
#/   ANIMEPAHE_EPISODES             default -e value (useful with --headless)
#/   ANIMEPAHE_RESOLUTION/AUDIO/THREADS/SEGMENT_TIMEOUT   defaults for -r/-o/-t/-T
#/   ANIMEPAHE_JS_RUNTIME           default for --js-runtime
#/   ANIMEPAHE_HEADLESS=true        default for --headless
#/   ANIMEPAHE_NO_RESUME=1          default for --no-resume
#/   ANIMEPAHE_KEEP_WORKDIR=1       default for --keep-workdir
#/   ANIMEPAHE_DOWNLOAD_NOTIFICATION=true   desktop notification when finished
#/   ANIMEPAHE_HLS_SEQ_IV=1         use the media-sequence IV (HLS spec) instead
#/                                  of an all-zero IV when the playlist has none
#/   ANIMEPAHE_CURL                 curl binary to use (default: newest curl_chromeNN
#/                                  from curl-impersonate if installed, else curl)
#/   ANIMEPAHE_BROWSER              Chrome/Chromium/Brave/Edge binary for --login
#/   ANIMEPAHE_BROWSER_ARGS         extra browser flags for --login (e.g. --no-sandbox)
#/   ANIMEPAHE_LOGIN_TIMEOUT        seconds to wait for the check to pass (default 180)
#/   ANIMEPAHE_TEMP_PROFILE=1       use a throwaway browser profile for --login instead of
#/                                  the persistent one in ~/.cache/animepahe-dl/profile
#/   ANIMEPAHE_AUTO_LOGIN=1         don't ask before opening the browser when blocked
#/   ANIMEPAHE_USE_BROWSER=1        always route site requests through a temporary
#/                                  browser (set automatically by --login when needed)
#/   ANIMEPAHE_CONFIG               path to an alternative config file

# ---------------------------------------------------------------------------
# Requirements check (before anything bash-4.4-specific is parsed)
# ---------------------------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
    printf 'animepahe-dl needs bash 4.4 or newer (this is %s).\n' "$BASH_VERSION" >&2
    printf 'On macOS: brew install bash, then run it with the new bash.\n' >&2
    exit 1
fi

set -euo pipefail

readonly VERSION="2.5.0"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
_ANIME_NAME=""
_ANIME_SLUG=""
_INPUT_ANIME_NAME=""
_ANIME_EPISODE=""
_ANIME_RESOLUTION=""
_ANIME_AUDIO=""
_LIST_LINK_ONLY=""
_DEBUG=""
_HEADLESS=""
_RESUME=1
_KEEP_WORKDIR=""
_NOTIFY=""
_NO_COLOR_FLAG=""
_LOGIN=""
_LOGIN_PID=""
_LOGIN_DIR=""
_PROXY_MODE=""
_CURL_KIND=""
_YTDLP=""
_USE_YTDLP=""
_SEGMENT_REFERER=""
_FALLBACK_OK=""
_DL_CODE=0
_REFRESH=""
_EP_FROM_CACHE=""
_EP_CACHE_AGE=0
_LIST_REFRESHED=""
_SEL_WARNINGS=0
_PROXY_PORT=""
_PROXY_RUNNER=()
_THREADS=4
_SEGMENT_TIMEOUT=""
_JS_RUNTIME_REQ=""
_JS_RUNTIME=""
_JS_NAME=""
_JS_CMD=()
_JS_SANDBOX=""
_FZF=""
_TIMEOUT=""
_NOTIFY_CMD=""
_COOKIE=""
_WORKDIR=""
_HLS_KEY=""
_MEDIA_SEQ=0
_HLS_KEYLINE=""
_ALL_EPS=()
_SELECTED_EPS=()
_SEG_URLS=()
_SEG_FILES=()
_OK_EPS=()
_SKIP_EPS=()
_FAIL_EPS=()
_MON_PID=""
_IND="  "
_T0=$SECONDS
_RESOLVED=""
_SEGNAME=""
_TTY_UI=""

# ---------------------------------------------------------------------------
# UI helpers — everything user-facing goes to stderr so `-l` stays pipeable
# ---------------------------------------------------------------------------
init_ui() {
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
    _TTY_UI=""
    if [[ -t 2 && "${TERM:-}" != dumb ]]; then
        _TTY_UI=1
    fi
    if [[ -t 2 && -z "${NO_COLOR:-}" && -z "$_NO_COLOR_FLAG" && "${TERM:-}" != dumb ]]; then
        RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'
        CYAN=$'\033[36m' BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
    fi
    local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ "$loc" =~ [Uu][Tt][Ff]-?8 ]]; then
        S_OK="✔" S_ERR="✘" S_WARN="▲" S_INFO="•" S_RUN="›" S_SKIP="↷"
        S_BAR_ON="█" S_BAR_OFF="░" S_RULE="─" S_SEC="▌"
    else
        S_OK="+" S_ERR="x" S_WARN="!" S_INFO="*" S_RUN=">" S_SKIP="-"
        S_BAR_ON="#" S_BAR_OFF="." S_RULE="-" S_SEC="|"
    fi
}

_out() { printf '%s\n' "$*" >&2; }

ui_banner() {
    _out ""
    _out "${BOLD}${CYAN}animepahe-dl${NC} ${DIM}v${VERSION}${NC}"
}

ui_section() {
    _out ""
    _out "${BOLD}${BLUE}${S_SEC}${NC} ${BOLD}$1${NC}"
}

ui_rule() {
    local r
    printf -v r '%*s' 46 ''
    _out "${DIM}${r// /$S_RULE}${NC}"
}

# ui_row <ok|warn|err|info|skip|run> <label> [detail]
ui_row() {
    local kind=$1 label=$2 detail=${3:-} sym col
    case $kind in
        ok)   sym=$S_OK   col=$GREEN ;;
        warn) sym=$S_WARN col=$YELLOW ;;
        err)  sym=$S_ERR  col=$RED ;;
        skip) sym=$S_SKIP col=$DIM ;;
        run)  sym=$S_RUN  col=$CYAN ;;
        *)    sym=$S_INFO col=$BLUE ;;
    esac
    printf '%s%s%s%s %s%-12s%s %s\n' "$_IND" "$col" "$sym" "$NC" "$BOLD" "$label" "$NC" "$detail" >&2
}

ui_warn() { _out "${_IND}${YELLOW}${S_WARN}${NC} $*"; }
ui_dim()  { _out "${_IND}${DIM}$*${NC}"; }
debug()   { if [[ -n "$_DEBUG" ]]; then _out "${DIM}[debug] $*${NC}"; fi; }

die() {
    _out "${_IND}${RED}${S_ERR} Error:${NC} $*"
    exit 1
}

# Single-line live status (TTY only); cleared by ui_live_clear
ui_live() {
    if [[ -n "$_TTY_UI" ]]; then printf '\r\033[K%s%s%s%s %s' "$_IND" "$CYAN" "$S_RUN" "$NC" "$1" >&2; fi
}
ui_live_clear() {
    if [[ -n "$_TTY_UI" ]]; then printf '\r\033[K' >&2; fi
}

# File modification time (GNU stat, then BSD/macOS stat) → age in seconds
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0'; }
file_age() {
    local m now age
    m=$(file_mtime "$1"); now=$(date +%s)
    age=$(( now - m ))
    if (( age < 0 )); then age=0; fi
    printf '%d' "$age"
}
fmt_age() {
    local s=$1
    if (( s < 90 )); then printf 'just now'
    elif (( s < 5400 )); then printf '%d min ago' $(( (s + 30) / 60 ))
    elif (( s < 129600 )); then printf '%d h ago' $(( (s + 1800) / 3600 ))
    else printf '%d days ago' $(( s / 86400 ))
    fi
}

tilde_path() {
    if [[ -n "${HOME:-}" && "$1" == "$HOME"* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi
}

fmt_duration() {
    local s=$1
    if (( s >= 3600 )); then
        printf '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
    elif (( s >= 60 )); then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

set_title() {
    if [[ -t 1 && -z "$_LIST_LINK_ONLY" ]]; then printf '\033]0;%s\007' "$1"; fi
}

# ---------------------------------------------------------------------------
# Progress bar: a background monitor counts lines in a log file that each
# parallel job appends to when it finishes.
# ---------------------------------------------------------------------------
draw_bar() { # count total start label
    local cnt=$1 total=$2 start=$3 label=$4
    local pct=0 width cols filled eta="" elapsed bar_on bar_off
    elapsed=$(( SECONDS - start ))
    if (( total > 0 )); then pct=$(( cnt * 100 / total )); fi
    cols=${_COLS:-80}
    width=$(( cols - 50 ))
    if (( width < 12 )); then width=12; fi
    if (( width > 36 )); then width=36; fi
    filled=$(( pct * width / 100 ))
    printf -v bar_on '%*s' "$filled" ''
    printf -v bar_off '%*s' $(( width - filled )) ''
    bar_on=${bar_on// /$S_BAR_ON}
    bar_off=${bar_off// /$S_BAR_OFF}
    if (( cnt > 0 && cnt < total && elapsed >= 3 )); then
        eta="  ETA $(fmt_duration $(( elapsed * (total - cnt) / cnt )))"
    fi
    printf '%s%s%s%s %s%-12s%s %s%s%s%s%s %3d%%  %d/%d%s' \
        "$_IND" "$CYAN" "$S_RUN" "$NC" "$BOLD" "$label" "$NC" \
        "$GREEN" "$bar_on" "$DIM" "$bar_off" "$NC" "$pct" "$cnt" "$total" "$eta"
}

progress_loop() { # label total base file start
    local label=$1 total=$2 base=$3 file=$4 start=$5 n cnt pct step last_step=0
    _COLS=$(tput cols 2>/dev/null || echo 80)
    [[ "$_COLS" =~ ^[0-9]+$ ]] || _COLS=80
    while :; do
        n=$(wc -l <"$file" 2>/dev/null || true)
        n=${n//[[:space:]]/}
        cnt=$(( base + ${n:-0} ))
        if [[ -n "$_TTY_UI" ]]; then
            printf '\r\033[K%s' "$(draw_bar "$cnt" "$total" "$start" "$label")" >&2
        else
            pct=$(( total > 0 ? cnt * 100 / total : 100 ))
            step=$(( pct / 25 ))
            if (( step > last_step )); then
                last_step=$step
                printf '%s%s %-12s %d%% (%d/%d)\n' "$_IND" "$S_RUN" "$label" "$pct" "$cnt" "$total" >&2
            fi
        fi
        sleep 0.4
    done
}

progress_start() { # label total base file
    ( progress_loop "$1" "$2" "$3" "$4" "$SECONDS" ) &
    _MON_PID=$!
}

progress_stop() {
    if [[ -n "$_MON_PID" ]]; then
        kill "$_MON_PID" 2>/dev/null || true
        wait "$_MON_PID" 2>/dev/null || true
        _MON_PID=""
    fi
    ui_live_clear
}

# ---------------------------------------------------------------------------
# Cleanup & signals
# ---------------------------------------------------------------------------
cleanup() {
    login_cleanup
    if [[ -n "$_MON_PID" ]]; then
        kill "$_MON_PID" 2>/dev/null || true
        _MON_PID=""
    fi
}

on_signal() {
    local code=$1
    trap - EXIT INT TERM
    cleanup
    printf '\n' >&2
    if [[ -n "$_RESUME" ]]; then
        ui_warn "Interrupted. Partial downloads are kept — re-run the same command to resume."
    else
        ui_warn "Interrupted."
    fi
    exit "$code"
}

usage() {
    sed -n 's/^#\/ \{0,1\}//p' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# KEY=VALUE lines; only ANIMEPAHE_* keys are accepted; real env vars win.
config_file_path() {
    printf '%s' "${ANIMEPAHE_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/animepahe-dl/config.env}"
}

load_config() {
    local f
    f=$(config_file_path)
    [[ -f "$f" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(ANIMEPAHE_[A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key=${BASH_REMATCH[2]}
        val=${BASH_REMATCH[3]}
        val=${val%"${val##*[![:space:]]}"}
        if [[ "$val" == \"*\" && ${#val} -ge 2 ]] || [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then
            val=${val:1:${#val}-2}
        fi
        if [[ -z "${!key:-}" ]]; then
            export "$key=$val"
        fi
    done <"$f"
}

apply_env_defaults() {
    if [[ "${ANIMEPAHE_HEADLESS:-false}" == "true" || "${ANIMEPAHE_AUTO_SELECT:-0}" == "1" ]]; then _HEADLESS=1; fi
    if [[ "${ANIMEPAHE_NO_RESUME:-0}" == "1" ]]; then _RESUME=""; fi
    if [[ "${ANIMEPAHE_KEEP_WORKDIR:-0}" == "1" ]]; then _KEEP_WORKDIR=1; fi
    if [[ "${ANIMEPAHE_DOWNLOAD_NOTIFICATION:-false}" == "true" ]]; then _NOTIFY=1; fi
    _SEGMENT_TIMEOUT="${ANIMEPAHE_SEGMENT_TIMEOUT:-}"
    _ANIME_RESOLUTION="${ANIMEPAHE_RESOLUTION:-}"
    _ANIME_AUDIO="${ANIMEPAHE_AUDIO:-}"
    _THREADS="${ANIMEPAHE_THREADS:-4}"
    _JS_RUNTIME_REQ="${ANIMEPAHE_DL_NODE:-${ANIMEPAHE_JS_RUNTIME:-}}"
}

parse_args() {
    local arg opt val has_val rest
    while (( $# )); do
        arg=$1; shift
        case $arg in
            --) break ;;
            --*)
                has_val=0
                if [[ "$arg" == --*=* ]]; then opt=${arg%%=*}; val=${arg#*=}; has_val=1; else opt=$arg; val=""; fi
                case $opt in
                    --help)          usage 0 ;;
                    --version)       printf 'animepahe-dl %s\n' "$VERSION"; exit 0 ;;
                    --headless)      _HEADLESS=1 ;;
                    --no-resume)     _RESUME="" ;;
                    --keep-workdir)  _KEEP_WORKDIR=1 ;;
                    --ytdlp)         _USE_YTDLP=1 ;;
                    --refresh)       _REFRESH=1 ;;
                    --clean-workdir) : ;; # deprecated: cleaning is now the default
                    --no-color)      _NO_COLOR_FLAG=1 ;;
                    --login)         _LOGIN=1 ;;
                    --js-runtime)
                        if (( ! has_val )); then
                            (( $# )) || die "--js-runtime requires a value (node, bun, deno, or a path)."
                            val=$1; shift
                        fi
                        _JS_RUNTIME_REQ=$val ;;
                    *) die "Unknown option: $arg (see --help)" ;;
                esac
                ;;
            -?*)
                rest=${arg:1}
                while [[ -n "$rest" ]]; do
                    opt=${rest:0:1}; rest=${rest:1}
                    case $opt in
                        h) usage 0 ;;
                        l) _LIST_LINK_ONLY=1 ;;
                        d) _DEBUG=1 ;;
                        y) _HEADLESS=1 ;;
                        a|s|e|r|o|t|T)
                            if [[ -n "$rest" ]]; then
                                val=$rest; rest=""
                            else
                                (( $# )) || die "Option -$opt requires an argument."
                                val=$1; shift
                            fi
                            case $opt in
                                a) _INPUT_ANIME_NAME=$val ;;
                                s) _ANIME_SLUG=$val ;;
                                e) _ANIME_EPISODE=$val ;;
                                r) _ANIME_RESOLUTION=$val ;;
                                o) _ANIME_AUDIO=$val ;;
                                t) _THREADS=$val ;;
                                T) _SEGMENT_TIMEOUT=$val ;;
                            esac
                            ;;
                        *) die "Unknown option: -$opt (see --help)" ;;
                    esac
                done
                ;;
            *) die "Unexpected argument: $arg (see --help)" ;;
        esac
    done
    if (( $# )); then die "Unexpected argument: $1 (see --help)"; fi

    [[ "$_THREADS" =~ ^[1-9][0-9]*$ ]] || die "-t: threads must be a positive integer (got '$_THREADS')."
    if [[ -n "$_SEGMENT_TIMEOUT" && ! "$_SEGMENT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        die "-T: timeout must be a positive integer in seconds (got '$_SEGMENT_TIMEOUT')."
    fi
    _ANIME_RESOLUTION=${_ANIME_RESOLUTION%p}
    # Fully-specified run without a terminal can never prompt
    if [[ -n "${_INPUT_ANIME_NAME}${_ANIME_SLUG}" && -n "$_ANIME_EPISODE" && ! -t 0 ]]; then
        _HEADLESS=1
    fi
}

# ---------------------------------------------------------------------------
# Environment setup
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found — please install it."
}

set_js_runtime() {
    local cand=""
    if [[ -n "$_JS_RUNTIME_REQ" ]]; then
        if [[ -x "$_JS_RUNTIME_REQ" ]]; then
            _JS_RUNTIME=$_JS_RUNTIME_REQ
        else
            _JS_RUNTIME=$(command -v "$_JS_RUNTIME_REQ" 2>/dev/null) || die "JS runtime not found: $_JS_RUNTIME_REQ"
        fi
    else
        for cand in node bun deno; do
            if _JS_RUNTIME=$(command -v "$cand" 2>/dev/null); then break; fi
            _JS_RUNTIME=""
        done
        [[ -n "$_JS_RUNTIME" ]] || die "No JS runtime found. Install node (default), bun or deno, or use --js-runtime."
    fi
    _JS_NAME=${_JS_RUNTIME##*/}
    _JS_CMD=("$_JS_RUNTIME")
    _JS_SANDBOX=""
    case $_JS_NAME in
        node*)
            # Node >= 22: --permission, Node 20/21: --experimental-permission
            if "$_JS_RUNTIME" --permission '--allow-fs-read=*' -e 0 >/dev/null 2>&1; then
                _JS_CMD+=(--permission '--allow-fs-read=*'); _JS_SANDBOX=1
            elif "$_JS_RUNTIME" --experimental-permission '--allow-fs-read=*' -e 0 >/dev/null 2>&1; then
                _JS_CMD+=(--experimental-permission '--allow-fs-read=*'); _JS_SANDBOX=1
            fi
            ;;
        deno*) _JS_CMD+=(run --allow-read); _JS_SANDBOX=1 ;;
    esac
}

set_var() {
    need curl; need jq; need ffmpeg; need openssl; need xargs; need mktemp
    pick_curl
    _YTDLP=$(command -v yt-dlp 2>/dev/null || true)
    _JQ=$(command -v jq)
    _FFMPEG=$(command -v ffmpeg)
    _OPENSSL=$(command -v openssl)
    _MKTEMP=$(command -v mktemp)

    _FZF=$(command -v fzf 2>/dev/null || true)
    if [[ -z "$_FZF" && -z "$_HEADLESS" && -t 0 && -t 2 ]]; then
        debug "fzf not found; using a numbered menu"
    fi
    _TIMEOUT=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
    _NOTIFY_CMD=$(command -v notify-send 2>/dev/null || true)
    set_js_runtime

    _HOST="${ANIMEPAHE_HOST:-https://animepahe.pw}"
    _HOST=${_HOST%/}
    _API_URL="$_HOST/api"
    _REFERER_URL="$_HOST/"   # browsers always send a path, even for the root page
    _USER_AGENT="${ANIMEPAHE_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36}"
    _ACCEPT_HTML="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    _ACCEPT_LANG="en-US,en;q=0.9"

    local vdir="${ANIMEPAHE_VIDEO_DIR:-${HOME:-$PWD}/Videos}"
    mkdir -p "$vdir" || die "Cannot create video directory: $vdir"
    _VIDEO_DIR_PATH=$(cd "$vdir" && pwd -P)   # absolute, so ffmpeg paths never drift
    _ANIME_LIST_FILE="${ANIMEPAHE_LIST_FILE:-$_VIDEO_DIR_PATH/anime.list}"
    _SOURCE_FILE=".source.json"

    export _CURL _USER_AGENT _ACCEPT_LANG _REFERER_URL _HOST _OPENSSL _SEGMENT_TIMEOUT _SEGMENT_REFERER

    local sb="no sandbox"
    if [[ -n "$_JS_SANDBOX" ]]; then sb="sandboxed"; fi
    local cu=${_CURL##*/}
    if [[ "$_CURL_KIND" == plain ]]; then cu="$cu (no browser impersonation)"; fi
    ui_row ok "Ready" "$_JS_NAME ($sb) · $cu · $_THREADS thread(s) · $(tilde_path "$_VIDEO_DIR_PATH")"
    if [[ -z "$_JS_SANDBOX" ]]; then
        ui_warn "$_JS_NAME has no permission sandbox; node >= 20 or deno is recommended."
    fi
}

# Cloudflare clearance cookie (browser devtools), else a throwaway one
set_cookie() {
    if [[ -n "${ANIMEPAHE_CF:-}" ]]; then
        _COOKIE=$ANIMEPAHE_CF
    else
        local u
        u=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16 || true)
        _COOKIE="__ddg2_=$u"
    fi
    export _COOKIE
}

# ---------------------------------------------------------------------------
# Browser login: temporary profile + DevTools protocol.
# 1. open the site in a throwaway browser profile and wait until the page has
#    REALLY loaded (not a "Just a moment..." challenge page)
# 2. check the site's API from inside the browser
# 3. save cookie + User-Agent; if curl is still refused, keep the browser open
#    and send requests to the site through it ("browser mode")
# ---------------------------------------------------------------------------
read -r -d '' _BROWSER_JS_LIB <<'JS' || true
const args = typeof Deno !== "undefined" ? Deno.args : process.argv.slice(2);
const log = (m) => console.error(m);
if (typeof WebSocket !== "function") { log("This JS runtime has no global WebSocket (need Node 22+, Bun or Deno)."); process.exit(3); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let id = 0; const pending = new Map();
    ws.onerror = () => reject(new Error("websocket error"));
    ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
    ws.onopen = () => resolve({
      send: (method, params = {}) => new Promise((res) => {
        const i = ++id; pending.set(i, res);
        ws.send(JSON.stringify({ id: i, method, params }));
        setTimeout(() => { if (pending.has(i)) { pending.delete(i); res({ error: "timeout" }); } }, 30000);
      }),
      close: () => ws.close(),
    });
  });
}
async function devtools(port, path, tries = 75) {
  for (let i = 0; i < tries; i++) {
    try { return await (await fetch(`http://127.0.0.1:${port}${path}`)).json(); } catch { await sleep(200); }
  }
  return null;
}
async function pageSocket(port, origin) {
  for (let i = 0; i < 75; i++) {
    const list = (await devtools(port, "/json/list", 1)) || [];
    const pages = list.filter((t) => t.type === "page" && t.webSocketDebuggerUrl);
    const p = pages.find((t) => t.url.startsWith(origin)) || pages[0];
    if (p) return connect(p.webSocketDebuggerUrl);
    await sleep(200);
  }
  return null;
}
async function evaluate(pg, expression) {
  const r = await pg.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  return r.result && r.result.result ? r.result.result.value : undefined;
}
JS

read -r -d '' _LOGIN_JS_BODY <<'JS' || true
const [port, host, timeoutSec] = args;
const origin = new URL(host).origin;
const hostname = new URL(host).hostname;
const challengeTitle = /just a moment|attention required|checking your browser|ddos-guard|security check|verify(ing)? (that )?you are (a )?human/i;
const API = `fetch("/api?m=search&q=a",{credentials:"include"}).then(r=>r.status).catch(()=>0)`;
const inScope = (c) => { const d = c.domain.replace(/^\./, ""); return hostname === d || hostname.endsWith("." + d); };

// PASSIVE wait: while the challenge runs we do NOT attach to the tab or run any
// JavaScript in it. We only read tab titles (plain HTTP /json/list) and cookies
// (browser-level), which is what a person with the window open would see anyway.
async function sitePage() {
  const list = (await devtools(port, "/json/list", 1)) || [];
  return list.filter((t) => t.type === "page").find((t) => (t.url || "").startsWith(origin)) || null;
}

async function main() {
  const info = await devtools(port, "/json/version");
  if (!info) { log("DevTools endpoint not reachable."); return 4; }
  const browser = await connect(info.webSocketDebuggerUrl);
  const ua = (await browser.send("Browser.getVersion")).result.userAgent;

  const t0 = Date.now();
  const deadline = t0 + Number(timeoutSec) * 1000;
  let announced = false, hinted = false, stable = 0, arrived = false, cookies = [];
  while (Date.now() < deadline) {
    const p = await sitePage();
    cookies = ((await browser.send("Storage.getCookies")).result?.cookies || []).filter(inScope);
    const clearance = cookies.some((c) => c.name === "cf_clearance");
    const onChallenge = !p || challengeTitle.test(p.title || "");
    stable = onChallenge ? 0 : stable + 1;
    // normal title + clearance cookie → done; no cookie (unprotected site) → 3 s of normal title
    if (!onChallenge && (clearance ? stable >= 2 : stable >= 6)) { arrived = true; log(`Page loaded: ${p.title}`); break; }
    if (onChallenge && !announced) { log("Waiting for the site's browser check to finish (tick the checkbox if one appears)…"); announced = true; }
    if (!hinted && Date.now() - t0 > 45000) {
      log("Still waiting. If the checkbox keeps looping: turn off any VPN/proxy, try real Google Chrome (ANIMEPAHE_BROWSER=google-chrome), or open the site in your normal browser to see whether it passes there.");
      hinted = true;
    }
    await sleep(500);
  }
  if (!arrived) { log("Timed out waiting for the page to load."); return 2; }

  // The check is over: now it is safe to look inside the page.
  let apiStatus = 0;
  const pg = await pageSocket(port, origin);
  if (pg) {
    for (let i = 0; i < 6; i++) {
      apiStatus = Number(await evaluate(pg, API).catch(() => 0)) || 0;
      if (apiStatus === 200) break;
      await sleep(1000);
    }
  }
  cookies = ((await browser.send("Storage.getCookies")).result?.cookies || []).filter(inScope);
  process.stdout.write(JSON.stringify({ ua, cookie: cookies.map((c) => `${c.name}=${c.value}`).join("; "), api_status: apiStatus }));
  return 0;
}
main().then((c) => process.exit(c), (e) => { log(String(e)); process.exit(1); });
JS

read -r -d '' _FETCH_JS_BODY <<'JS' || true
const [port, host, url] = args;
const origin = new URL(host).origin;
const accept = url.includes("/api") ? "application/json, text/plain, */*" : "text/html,application/xhtml+xml,*/*;q=0.8";
async function main() {
  const pg = await pageSocket(port, origin);
  if (!pg) { log("No browser tab found."); return 4; }
  const expr = `fetch(${JSON.stringify(url)},{credentials:"include",headers:{Accept:${JSON.stringify(accept)}}}).then(async r=>({status:r.status,body:await r.text()}))`;
  const v = await evaluate(pg, expr);
  if (!v) { log("fetch failed inside the browser."); return 1; }
  process.stdout.write(JSON.stringify(v));
  return 0;
}
main().then((c) => process.exit(c), (e) => { log(String(e)); process.exit(1); });
JS

find_browser() {
    local c p
    if [[ -n "${ANIMEPAHE_BROWSER:-}" ]]; then
        if p=$(command -v "$ANIMEPAHE_BROWSER" 2>/dev/null) || { [[ -x "$ANIMEPAHE_BROWSER" ]] && p=$ANIMEPAHE_BROWSER; }; then
            printf '%s' "$p"; return 0
        fi
        return 1
    fi
    for c in google-chrome google-chrome-stable chromium chromium-browser brave-browser brave \
             microsoft-edge microsoft-edge-stable chrome; do
        if p=$(command -v "$c" 2>/dev/null); then printf '%s' "$p"; return 0; fi
    done
    for p in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
             "/Applications/Chromium.app/Contents/MacOS/Chromium" \
             "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
             "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
        if [[ -x "$p" ]]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

login_cleanup() {
    _PROXY_MODE=""
    if [[ -n "$_LOGIN_PID" ]]; then
        kill "$_LOGIN_PID" 2>/dev/null || true
        wait "$_LOGIN_PID" 2>/dev/null || true
        _LOGIN_PID=""
    fi
    if [[ -n "$_LOGIN_DIR" && -d "$_LOGIN_DIR" ]]; then
        sleep 0.3   # let the browser release its profile files
        rm -rf "$_LOGIN_DIR" 2>/dev/null || { sleep 1; rm -rf "$_LOGIN_DIR" 2>/dev/null || true; }
    fi
    _LOGIN_DIR=""
}

# config_set KEY VALUE — upsert into the config file (mode 600)
config_set() {
    local key=$1 val=$2 f dir tmp
    val=${val//$'\n'/}; val=${val//\"/}
    f=$(config_file_path); dir=$(dirname "$f")
    mkdir -p "$dir" && chmod 700 "$dir" 2>/dev/null || true
    tmp=$("$_MKTEMP" "$dir/.config.XXXXXX")
    if [[ -f "$f" ]]; then
        grep -Ev "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$f" >"$tmp" || true
    fi
    printf '%s="%s"\n' "$key" "$val" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$f"
}

# Raw curl status (never goes through the browser)
curl_status() { # url → HTTP status code (000 on network failure)
    local url=$1 code
    local -a h=(-A "$_USER_AGENT" -H "Accept: $_ACCEPT_HTML" -H "Accept-Language: $_ACCEPT_LANG" -H "Referer: $_REFERER_URL")
    if [[ "$url" == "$_HOST"/* ]]; then h+=(-H "cookie: $_COOKIE"); fi
    code=$("$_CURL" -sS -L -o /dev/null -w '%{http_code}' --compressed --max-time 20 "${h[@]}" "$url" 2>/dev/null || true)
    printf '%s' "${code:-000}"
}

# Browser mode: fetch a same-origin URL inside the open browser tab → JSON {status, body}
browser_fetch_json() { # url
    "${_PROXY_RUNNER[@]}" "$_LOGIN_DIR/fetch.js" "$_PROXY_PORT" "$_HOST" "$1" 2>/dev/null
}

http_status() { # url → status, via the browser when in browser mode
    local url=$1 out st
    if [[ -n "$_PROXY_MODE" && "$url" == "$_HOST"/* ]]; then
        out=$(browser_fetch_json "$url") || { printf '000'; return 0; }
        st=$("$_JQ" -r '.status // 0' <<<"$out" 2>/dev/null) || st=000
        printf '%s' "$st"
        return 0
    fi
    curl_status "$url"
}

browser_login() {
    local browser cache work prof i out rc=0 cf ua api code port="" cfg
    local -a extra=()
    if [[ -n "$_LOGIN_PID" ]]; then login_cleanup; fi
    ui_section "Browser login"
    browser=$(find_browser) || die "No Chrome/Chromium/Brave/Edge found. Install one, set ANIMEPAHE_BROWSER, or set ANIMEPAHE_CF manually."
    ui_row info "Browser" "$(basename "$browser")"

    # Inside $HOME (not /tmp) so snap/flatpak browsers can write the profile
    cache="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/animepahe-dl"
    mkdir -p "$cache"
    work=$("$_MKTEMP" -d "$cache/session.XXXXXX") || die "Cannot create a temporary profile directory."
    _LOGIN_DIR=$work
    # A persistent dedicated profile builds trust with the site (and may keep the
    # clearance cookie, so later runs often pass instantly). ANIMEPAHE_TEMP_PROFILE=1
    # uses a throwaway one instead.
    if [[ "${ANIMEPAHE_TEMP_PROFILE:-0}" == "1" ]]; then prof="$work/profile"; else prof="$cache/profile"; fi
    mkdir -p "$prof"
    rm -f "$prof/DevToolsActivePort"   # never trust a stale port file
    printf '%s\n%s\n' "$_BROWSER_JS_LIB" "$_LOGIN_JS_BODY" >"$work/login.js"
    printf '%s\n%s\n' "$_BROWSER_JS_LIB" "$_FETCH_JS_BODY" >"$work/fetch.js"

    if [[ -n "${ANIMEPAHE_BROWSER_ARGS:-}" ]]; then read -r -a extra <<<"$ANIMEPAHE_BROWSER_ARGS"; fi
    "$browser" --user-data-dir="$prof" --remote-debugging-port=0 --remote-allow-origins='*' \
        --no-first-run --no-default-browser-check --disable-blink-features=AutomationControlled \
        "${extra[@]}" "$_HOST/" >/dev/null 2>&1 &
    _LOGIN_PID=$!

    for (( i = 0; i < 100; i++ )); do
        if [[ -s "$prof/DevToolsActivePort" ]]; then port=$(head -n 1 "$prof/DevToolsActivePort"); break; fi
        if ! kill -0 "$_LOGIN_PID" 2>/dev/null; then break; fi
        sleep 0.2
    done
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        login_cleanup
        die "The browser did not start with a DevTools port. Close any other window opened by animepahe-dl, or (as root) try ANIMEPAHE_BROWSER_ARGS=--no-sandbox."
    fi

    case $_JS_NAME in
        deno*) _PROXY_RUNNER=("$_JS_RUNTIME" run --allow-net) ;;
        *)     _PROXY_RUNNER=("$_JS_RUNTIME") ;;
    esac
    ui_row run "Waiting" "for the site to load in the window — the script only watches, it does not touch the page"
    out=$("${_PROXY_RUNNER[@]}" "$work/login.js" "$port" "$_HOST" "${ANIMEPAHE_LOGIN_TIMEOUT:-180}") || rc=$?
    case $rc in
        0) ;;
        2) login_cleanup; die "Timed out: the site never finished loading in the browser window." ;;
        3) login_cleanup; die "$_JS_NAME is too old for --login (needs a global WebSocket: Node 22+, Bun or Deno)." ;;
        *) login_cleanup; die "Browser login failed (code $rc)." ;;
    esac

    cf=$("$_JQ" -r '.cookie // empty' <<<"$out")
    ua=$("$_JQ" -r '.ua // empty' <<<"$out")
    api=$("$_JQ" -r '.api_status // 0' <<<"$out")
    [[ -n "$ua" ]] || { login_cleanup; die "The browser returned no User-Agent."; }
    ui_row ok "Page" "loaded in the browser (API check inside the browser: HTTP $api)"

    if [[ -n "$cf" ]]; then
        config_set ANIMEPAHE_CF "$cf"
        export ANIMEPAHE_CF="$cf"
        _COOKIE=$cf
    fi
    config_set ANIMEPAHE_UA "$ua"
    export ANIMEPAHE_UA="$ua"
    _USER_AGENT=$ua
    export _COOKIE _USER_AGENT
    cfg=$(config_file_path)
    ui_row ok "Cookie" "saved to $(tilde_path "$cfg") (mode 600)"

    code=$(curl_status "$_API_URL?m=search&q=a")
    if [[ "$code" == "200" ]]; then
        login_cleanup
        config_set ANIMEPAHE_USE_BROWSER 0
        ui_row ok "Verified" "curl is accepted with the new cookie"
    elif [[ "$api" == "200" ]]; then
        _PROXY_MODE=1
        _PROXY_PORT=$port
        config_set ANIMEPAHE_USE_BROWSER 1
        ui_row ok "Browser mode" "curl got HTTP $code (the site fingerprints it), but the browser is accepted"
        ui_dim "requests to the site now go through the browser window; keep it open (minimizing is fine)"
        ui_dim "future runs will open it automatically; downloads of the video data still use curl"
    else
        login_cleanup
        die "The site answers HTTP $api even inside the browser, so this is not a cookie problem. Check that ${_HOST} opens in a normal browser, or set ANIMEPAHE_HOST."
    fi
}

# Quick request before doing real work; offer a browser login if blocked
preflight() {
    local code a
    code=$(http_status "$_API_URL?m=search&q=a")
    case $code in
        403|429|503) ;;
        *) return 0 ;;
    esac
    ui_row warn "Blocked" "the site rejected the request (HTTP $code) — anti-bot check"
    if [[ -n "$_HEADLESS" || ! -t 0 || ! -t 2 ]]; then
        die "Blocked by the site. Run '${0##*/} --login' once to get a cookie, or set ANIMEPAHE_CF."
    fi
    if [[ "${ANIMEPAHE_AUTO_LOGIN:-0}" != "1" ]]; then
        read -r -p "  Open a temporary browser window to get past the check? [Y/n] " a
        case ${a:-y} in [Nn]*) die "Blocked by the site. Set ANIMEPAHE_CF or run with --login." ;; esac
    fi
    browser_login
    code=$(http_status "$_API_URL?m=search&q=a")
    case $code in
        403|429|503) die "Still blocked (HTTP $code) after the browser check." ;;
    esac
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
# Silent; returns curl's exit code. The cookie only goes to the animepahe host.
http_get() {
    local url=$1 out st
    if [[ -n "$_PROXY_MODE" && "$url" == "$_HOST"/* ]]; then
        out=$(browser_fetch_json "$url") || return 28
        st=$("$_JQ" -r '.status // 0' <<<"$out" 2>/dev/null) || return 28
        if [[ ! "$st" =~ ^2 ]]; then return 22; fi
        "$_JQ" -j '.body' <<<"$out"
        return
    fi
    local -a h=(-A "$_USER_AGENT" -H "Accept: $_ACCEPT_HTML" -H "Accept-Language: $_ACCEPT_LANG" -H "Referer: $_REFERER_URL")
    if [[ "$url" == "$_HOST"/* ]]; then h+=(-H "cookie: $_COOKIE"); fi
    "$_CURL" -sSL --fail --compressed --retry 2 --retry-delay 2 \
        --connect-timeout 15 --max-time 60 "${h[@]}" "$url" 2>/dev/null
}

# Choose the curl binary. curl-impersonate's curl_chromeNN wrapper scripts make
# TLS/HTTP2 look like real Chrome, which some hosts (e.g. the stream host) require.
pick_curl() {
    local c="" cand
    _CURL_KIND=plain
    if [[ -n "${ANIMEPAHE_CURL:-}" ]]; then
        c=$(command -v "$ANIMEPAHE_CURL" 2>/dev/null) || die "ANIMEPAHE_CURL not found: $ANIMEPAHE_CURL"
        _CURL_KIND=custom
    else
        c=$(compgen -c curl_chrome 2>/dev/null | grep -E '^curl_chrome[0-9]+$' | sort -V | tail -n 1 || true)
        if [[ -n "$c" ]]; then
            c=$(command -v "$c"); _CURL_KIND=impersonate
        else
            for cand in curl-impersonate-chrome curl-impersonate; do
                if c=$(command -v "$cand" 2>/dev/null); then _CURL_KIND=impersonate; break; fi
                c=""
            done
        fi
        if [[ -z "$c" ]]; then c=$(command -v curl); fi
    fi
    _CURL=$c
}

# One-line description of what a URL answers (status + Cloudflare hints)
curl_diag() { # url
    local url=$1 hdr code out
    local -a h=(-A "$_USER_AGENT" -H "Accept: $_ACCEPT_HTML" -H "Accept-Language: $_ACCEPT_LANG" -H "Referer: $_REFERER_URL")
    if [[ "$url" == "$_HOST"/* ]]; then h+=(-H "cookie: $_COOKIE"); fi
    hdr=$("$_CURL" -sS -L -o /dev/null -D - --max-time 20 --compressed "${h[@]}" "$url" 2>/dev/null || true)
    code=$(grep -i '^HTTP/' <<<"$hdr" | tail -n 1 | awk '{print $2}' || true)
    out="HTTP ${code:-no response}"
    if grep -qi '^cf-mitigated: *challenge' <<<"$hdr"; then
        out+=" · Cloudflare challenge page"
    elif grep -qi '^server: *cloudflare' <<<"$hdr"; then
        out+=" · served by Cloudflare"
    fi
    printf '%s' "$out"
}

curl_reason() { # rc [url]
    local rc=$1 url=${2:-}
    case $rc in
        6)  printf 'could not resolve host' ;;
        7)  printf 'connection refused' ;;
        22) if [[ -n "$url" && "$url" != "$_HOST"/* ]]; then
                printf 'the stream host refused the request'
            elif [[ -z "${ANIMEPAHE_CF:-}" ]]; then
                printf 'HTTP error — likely a Cloudflare check; run with --login to get a fresh cookie'
            else
                printf 'HTTP error — your cookie has probably expired; run with --login'
            fi ;;
        28) printf 'timed out' ;;
        35|60) printf 'TLS error' ;;
        *)  printf 'curl exit code %s' "$rc" ;;
    esac
}

# Hint printed when a non-site host refuses us
impersonation_hint() {
    if [[ "$_CURL_KIND" == plain ]]; then
        ui_dim "this host likely fingerprints plain curl. Install curl-impersonate (curl_chromeNN wrappers),"
        ui_dim "or set ANIMEPAHE_CURL, or use --ytdlp (needs yt-dlp with curl_cffi)."
    fi
}

ytdlp_download() { # playlist-url output
    local pl=$1 v=$2 rc=0
    [[ -n "$_YTDLP" ]] || { ui_row err "yt-dlp" "not installed"; return 1; }
    ui_row run "yt-dlp" "downloading with Chrome impersonation (referer ${_SEGMENT_REFERER:-none})"
    "$_YTDLP" "$pl" --referer "${_SEGMENT_REFERER:-$_REFERER_URL}" --impersonate chrome \
        --no-warnings -q --progress -o "$v" >&2 || rc=$?
    ui_live_clear
    if (( rc != 0 )) || [[ ! -s "$v" ]]; then
        rm -f "$v" "$v.part"
        ui_row err "yt-dlp" "failed (impersonation needs the curl_cffi Python package: pip install curl_cffi)"
        return 1
    fi
    ui_row ok "yt-dlp" "$(basename "$v") · $(du -h "$v" | cut -f1)"
}

# Exported to parallel jobs: silent, atomic (.part → rename), no UI.
# $1 url  $2 outfile  $3 retries  $4 base delay
download_file() {
    local url=$1 out=$2 retries=${3:-3} delay=${4:-2}
    local attempt=0 rc code part="${2}.part"
    _DL_CODE=0
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || return 2
    # Video data is referred from the stream page's site (e.g. https://kwik.cx/), not animepahe
    local -a h=(-A "$_USER_AGENT" -H "Accept: */*" -H "Accept-Language: $_ACCEPT_LANG" -H "Referer: ${_SEGMENT_REFERER:-$_REFERER_URL}")
    if [[ "$url" == "$_HOST"/* ]]; then h+=(-H "cookie: $_COOKIE"); fi
    while (( attempt < retries )); do
        attempt=$(( attempt + 1 )); rc=0
        rm -f "$part"
        code=$("$_CURL" -sS -L -g --compressed --connect-timeout 10 \
            --max-time "${_SEGMENT_TIMEOUT:-300}" "${h[@]}" -o "$part" -w '%{http_code}' "$url" 2>/dev/null) || rc=$?
        _DL_CODE=${code:-0}
        if (( rc == 0 )) && [[ "$code" == 2* && -s "$part" ]]; then
            mv -f "$part" "$out"
            return 0
        fi
        # A client error (403/404/...) will not fix itself: do not waste retries on it
        if [[ "$code" =~ ^4[0-9][0-9]$ && "$code" != 408 && "$code" != 429 ]]; then
            rm -f "$part"
            return 3
        fi
        if (( attempt < retries )); then sleep $(( delay * attempt )); fi
    done
    rm -f "$part"
    return 1
}

segment_job() { # url outfile — called via xargs
    local url=$1 out=$2
    if [[ "$(dirname -- "$out")" != "$_WORKDIR" ]]; then return 1; fi
    if [[ -s "$out" ]]; then printf 'x\n' >>"$_WORKDIR/.done"; return 0; fi   # already fetched by the probe
    if download_file "$url" "$out" 3 2; then
        printf 'x\n' >>"$_WORKDIR/.done"
    else
        printf '%s %s\n' "${_DL_CODE:-0}" "$url" >>"$_WORKDIR/.failed"
        return 1
    fi
}

decrypt_job() { # encrypted-file iv — key comes from $_HLS_KEY
    local enc=$1 iv=$2 out="${1%.encrypted}"
    if "$_OPENSSL" aes-128-cbc -d -K "$_HLS_KEY" -iv "$iv" -in "$enc" -out "$out.tmp" 2>/dev/null \
        && [[ -s "$out.tmp" ]]; then
        mv -f "$out.tmp" "$out"
        rm -f "$enc"
        printf 'x\n' >>"$_WORKDIR/.done"
    else
        rm -f "$out.tmp"
        printf '%s\n' "$enc" >>"$_WORKDIR/.failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Small pure helpers
# ---------------------------------------------------------------------------
sanitize_filename() {
    local s
    s=$(printf '%s' "$1" | sed -E -e 's/[^[:alnum:] ,+().!'"'"'_-]/_/g' -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//')
    if [[ -z "$s" || "$s" =~ ^\.+$ ]]; then s="_${s}"; fi
    printf '%s' "$s"
}

# Resolve an HLS URI against the playlist URL → $_RESOLVED (no forks)
resolve_url() { # base uri
    local base=$1 uri=${2%$'\r'} dir
    case $uri in
        http://*|https://*) _RESOLVED=$uri ;;
        //*) _RESOLVED="https:$uri" ;;
        /*)
            if [[ "$base" =~ ^(https?://[^/]+) ]]; then _RESOLVED="${BASH_REMATCH[1]}$uri"; else _RESOLVED=$uri; fi
            ;;
        *)
            dir=${base%%\?*}; dir=${dir%%\#*}; dir=${dir%/*}
            _RESOLVED="$dir/$uri"
            ;;
    esac
}

# Local segment filename → $_SEGNAME ("00042-name.ts")
segment_filename() { # url index
    local name=${1##*/} idx
    name=${name%%\?*}; name=${name%%\#*}
    name=${name//[^A-Za-z0-9._-]/_}
    if [[ -z "$name" ]]; then name="seg.ts"; fi
    printf -v idx '%05d' "$2"
    _SEGNAME="$idx-$name"
}

# Turn a list of numbers into compact ranges: 1 2 3 5 → "1-3, 5"
read -r -d '' _RANGE_AWK <<'AWK' || true
function flush() {
    if (start == "") return
    item = (start == prev) ? start : start "-" prev
    out = out (out == "" ? "" : sep) item
}
{
    v = $0
    if (start != "" && v ~ /^[0-9]+$/ && prev ~ /^[0-9]+$/ && v + 0 == prev + 1) { prev = v; next }
    flush(); start = v; prev = v
}
END { flush(); print out }
AWK

compact_ranges() { # sep numbers...
    local sep=$1; shift
    if (( $# == 0 )); then return 0; fi
    printf '%s\n' "$@" | sort -n -u | awk -v sep="$sep" "$_RANGE_AWK"
}

# Episode selection engine. stdin: available episodes (one per line, sorted).
# Output lines:  E<TAB>episode   or   W<TAB>warning
read -r -d '' _SELECT_AWK <<'AWK' || true
function trim(s) { gsub(/^[ \t"']+|[ \t"']+$/, "", s); return s }
function warn(m) { printf "W\t%s\n", m }
function mark(i, neg) { if (neg) ex[i] = 1; else inc[i] = 1 }
{ n++; eps[n] = $0 }
END {
    np = split(spec, parts, ",")
    for (p = 1; p <= np; p++) {
        pat = trim(parts[p]); if (pat == "") continue
        neg = 0
        if (substr(pat, 1, 1) == "!") { neg = 1; pat = substr(pat, 2); nex++ }
        else has_inc = 1
        if (pat == "*") {
            for (i = 1; i <= n; i++) mark(i, neg)
        } else if (pat ~ /^[Ll][0-9]+$/) {
            k = substr(pat, 2) + 0
            if (k < 1) { warn("Ignoring '" pat "' (needs a number > 0)"); continue }
            if (k > n) { warn("Only " n " episodes available; '" pat "' covers all of them"); k = n }
            for (i = n - k + 1; i <= n; i++) mark(i, neg)
        } else if (pat ~ /^[Ff][0-9]+$/) {
            k = substr(pat, 2) + 0
            if (k < 1) { warn("Ignoring '" pat "' (needs a number > 0)"); continue }
            if (k > n) { warn("Only " n " episodes available; '" pat "' covers all of them"); k = n }
            for (i = 1; i <= k; i++) mark(i, neg)
        } else if (pat ~ /^[0-9]+(\.[0-9]+)?-$/) {
            lo = substr(pat, 1, length(pat) - 1) + 0
            for (i = 1; i <= n; i++) if (eps[i] + 0 >= lo) mark(i, neg)
        } else if (pat ~ /^-[0-9]+(\.[0-9]+)?$/) {
            hi = substr(pat, 2) + 0
            for (i = 1; i <= n; i++) if (eps[i] + 0 <= hi) mark(i, neg)
        } else if (pat ~ /^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$/) {
            d = index(pat, "-"); lo = substr(pat, 1, d - 1) + 0; hi = substr(pat, d + 1) + 0
            if (lo > hi) { warn("Ignoring invalid range '" pat "'"); continue }
            for (i = 1; i <= n; i++) if (eps[i] + 0 >= lo && eps[i] + 0 <= hi) mark(i, neg)
        } else if (pat ~ /^[0-9]+(\.[0-9]+)?$/) {
            found = 0
            for (i = 1; i <= n; i++) if (eps[i] + 0 == pat + 0) { mark(i, neg); found = 1; break }
            if (!found) warn("Episode " pat " is not available")
        } else {
            warn("Unrecognized pattern '" pat "'")
        }
    }
    # Only exclusions given (e.g. "!5") → start from everything
    if (!has_inc && nex > 0) for (i = 1; i <= n; i++) inc[i] = 1
    for (i = 1; i <= n; i++) if (inc[i] && !ex[i]) printf "E\t%s\n", eps[i]
}
AWK

select_episodes() { # spec [quiet] → _SELECTED_EPS, _SEL_WARNINGS
    local spec=$1 quiet=${2:-} kind rest
    local -a result=()
    _SEL_WARNINGS=0
    while IFS=$'\t' read -r kind rest; do
        case $kind in
            W) _SEL_WARNINGS=$(( _SEL_WARNINGS + 1 ))
               if [[ -z "$quiet" ]]; then ui_warn "$rest"; fi ;;
            E) result+=("$rest") ;;
        esac
    done < <(printf '%s\n' "${_ALL_EPS[@]}" | awk -v spec="$spec" "$_SELECT_AWK")
    _SELECTED_EPS=("${result[@]}")
}

show_available_episodes() {
    local note=""
    if [[ -n "$_EP_FROM_CACHE" ]]; then note=" · cached $(fmt_age "$_EP_CACHE_AGE")"; fi
    ui_row info "Available" "${#_ALL_EPS[@]}  ($(compact_ranges ', ' "${_ALL_EPS[@]}"))${note}"
}

# ---------------------------------------------------------------------------
# Anime discovery
# ---------------------------------------------------------------------------
download_anime_list() {
    ui_live "Refreshing master anime list…"
    local content rc=0
    content=$(http_get "$_HOST/anime") || rc=$?
    ui_live_clear
    if (( rc != 0 )); then
        ui_warn "Could not fetch the master anime list: $(curl_reason "$rc")"
        return 1
    fi
    printf '%s\n' "$content" | grep '/anime/' \
        | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' >"$_ANIME_LIST_FILE.new" || true
    if [[ -s "$_ANIME_LIST_FILE.new" ]]; then
        mv -f "$_ANIME_LIST_FILE.new" "$_ANIME_LIST_FILE"
        _LIST_REFRESHED=1
        ui_row ok "Anime list" "$(wc -l <"$_ANIME_LIST_FILE" | tr -d ' ') titles · refreshed just now"
        return 0
    fi
    rm -f "$_ANIME_LIST_FILE.new"
    ui_warn "Could not parse the master anime list."
    return 1
}

# Trust the cached list while it is younger than the TTL (file modification time).
# A stale list is refreshed; if that fails, the stale one is still used.
ensure_anime_list() {
    local days=${ANIMEPAHE_LIST_CACHE_DAYS:-7} ttl age
    [[ "$days" =~ ^[0-9]+$ ]] || days=7
    ttl=$(( days * 86400 ))
    if [[ -s "$_ANIME_LIST_FILE" ]]; then
        age=$(file_age "$_ANIME_LIST_FILE")
        if [[ -z "$_REFRESH" ]] && (( age < ttl )); then
            ui_row ok "Anime list" "$(wc -l <"$_ANIME_LIST_FILE" | tr -d ' ') titles · cached $(fmt_age "$age")"
            return 0
        fi
        if download_anime_list; then return 0; fi
        ui_warn "Using the cached list from $(fmt_age "$age") instead."
        return 0
    fi
    download_anime_list
}

# Offline fallback: every word of the query must appear (case-insensitive)
search_local_list() { # name → "[slug] Title" lines
    [[ -s "$_ANIME_LIST_FILE" ]] || return 0
    awk -v q="$1" 'BEGIN { n = split(tolower(q), w, /[[:space:]]+/) }
        { l = tolower($0); ok = 1
          for (i = 1; i <= n; i++) if (w[i] != "" && index(l, w[i]) == 0) { ok = 0; break }
          if (ok) print }' "$_ANIME_LIST_FILE"
}

search_anime_by_name() { # → "[slug] Title" lines
    local query body rc=0 total
    query=$(printf %s "$1" | "$_JQ" -sRr @uri)
    body=$(http_get "$_API_URL?m=search&q=${query}") || rc=$?
    if (( rc != 0 )); then
        ui_warn "Search failed: $(curl_reason "$rc")"
        return 1
    fi
    total=$("$_JQ" -r '.total // 0' <<<"$body" 2>/dev/null || echo 0)
    if [[ "$total" == "0" || "$total" == "null" ]]; then return 0; fi
    "$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<<"$body" 2>/dev/null || true
}

# Pick one line from "[slug] Title" candidates: fzf → numbered menu → first.
choose_from_list() { # candidates noun
    local candidates=$1 noun=$2 count first choice n i
    local -a lines=()
    count=$(grep -c . <<<"$candidates" || true)
    if (( count == 0 )); then die "No $noun found."; fi
    first=${candidates%%$'\n'*}
    if (( count == 1 )); then printf '%s\n' "$first"; return 0; fi
    if [[ -n "$_HEADLESS" ]]; then
        ui_dim "headless: picked first of $count results"
        printf '%s\n' "$first"; return 0
    fi
    if [[ ! -t 0 || ! -t 2 ]]; then
        ui_warn "No terminal available; picked the first of $count results."
        printf '%s\n' "$first"; return 0
    fi
    if [[ -n "$_FZF" ]]; then
        choice=$("$_FZF" --height=50% --reverse --border --prompt="$noun › " \
            --delimiter='] ' --with-nth=2.. <<<"$candidates") || die "Selection cancelled."
        printf '%s\n' "$choice"; return 0
    fi
    mapfile -t lines <<<"$candidates"
    _out ""
    for i in "${!lines[@]}"; do
        if (( i >= 15 )); then ui_dim "… and $(( ${#lines[@]} - 15 )) more (refine your search)"; break; fi
        printf '  %s%2d%s  %s\n' "$BOLD" $(( i + 1 )) "$NC" "${lines[$i]#*] }" >&2
    done
    read -r -p "  Pick a number [1]: " n
    n=${n:-1}
    if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#lines[@]} || n > 15 )); then die "Invalid choice: $n"; fi
    printf '%s\n' "${lines[$(( n - 1 ))]}"
}

line_slug()  { local s=${1%%]*}; printf '%s' "${s#[}"; }
line_title() { local t=${1#*] }; printf '%s' "${t%"${t##*[![:space:]]}"}"; }

select_anime() {
    local line results=""
    ui_section "Anime"
    if [[ -n "$_INPUT_ANIME_NAME" ]]; then
        ui_live "Searching for '$_INPUT_ANIME_NAME'…"
        local api_ok=1
        results=$(search_anime_by_name "$_INPUT_ANIME_NAME") || api_ok=""
        ui_live_clear
        if [[ -z "$results" && -z "$api_ok" ]]; then
            results=$(search_local_list "$_INPUT_ANIME_NAME")
            if [[ -n "$results" ]]; then ui_warn "Search is unavailable; matched against the cached anime list instead."; fi
        fi
        [[ -n "$results" ]] || die "No anime found matching '$_INPUT_ANIME_NAME'."
        line=$(choose_from_list "$results" "anime")
        _ANIME_SLUG=$(line_slug "$line")
        _ANIME_NAME=$(line_title "$line")
    elif [[ -n "$_ANIME_SLUG" ]]; then
        [[ "$_ANIME_SLUG" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid anime slug: $_ANIME_SLUG"
        ensure_anime_list || true
        line=""
        if [[ -f "$_ANIME_LIST_FILE" ]]; then
            line=$(grep -F -m1 "[$_ANIME_SLUG]" "$_ANIME_LIST_FILE" || true)
            # New shows appear mid-week: on a miss, refresh once (at most hourly)
            if [[ -z "$line" && -z "$_LIST_REFRESHED" ]] && (( $(file_age "$_ANIME_LIST_FILE") > 3600 )); then
                ui_dim "slug not in the cached list; refreshing it…"
                if download_anime_list; then
                    line=$(grep -F -m1 "[$_ANIME_SLUG]" "$_ANIME_LIST_FILE" || true)
                fi
            fi
        fi
        if [[ -n "$line" ]]; then
            _ANIME_NAME=$(line_title "$line")
        else
            ui_warn "Slug not found in the anime list; using the slug as the folder name."
            _ANIME_NAME=$_ANIME_SLUG
        fi
    else
        [[ -z "$_HEADLESS" ]] || die "No anime specified. Use -a <name> or -s <slug> in headless mode."
        [[ -t 0 && -t 2 ]] || die "No anime specified and no terminal to ask on. Use -a <name> or -s <slug>."
        ensure_anime_list || die "No anime list available."
        line=$(choose_from_list "$(cat "$_ANIME_LIST_FILE")" "anime")
        _ANIME_SLUG=$(line_slug "$line")
        _ANIME_NAME=$(line_title "$line")
    fi
    [[ -n "$_ANIME_SLUG" && "$_ANIME_SLUG" =~ ^[A-Za-z0-9_-]+$ ]] || die "Could not determine a valid slug for '$_ANIME_NAME'."
    local original=$_ANIME_NAME
    _ANIME_NAME=$(sanitize_filename "$_ANIME_NAME")
    [[ -n "$_ANIME_NAME" ]] || die "Anime name is empty after sanitizing (was '$original')."
    ui_row ok "Selected" "${BOLD}${_ANIME_NAME}${NC} ${DIM}(${_ANIME_SLUG})${NC}"
    set_title "$_ANIME_NAME"
}

# ---------------------------------------------------------------------------
# Episode list
# ---------------------------------------------------------------------------
fetch_episode_page() { # slug page → body on stdout
    local body rc=0 attempt
    for attempt in 1 2 3; do
        rc=0
        body=$(http_get "$_API_URL?m=release&id=${1}&sort=episode_asc&page=${2}") || rc=$?
        if (( rc == 0 )) && "$_JQ" -e '.data' >/dev/null 2>&1 <<<"$body"; then
            printf '%s' "$body"; return 0
        fi
        sleep "$attempt"
    done
    _LAST_CURL_RC=$rc
    return 1
}

download_source() { # slug dir [force]
    local slug=$1 dir=$2 force=${3:-} ttl age
    local src="$dir/$_SOURCE_FILE" tmp="$dir/$_SOURCE_FILE.new"
    local page=1 last=1 body failed=0
    local -a chunks=()
    mkdir -p "$dir"
    local hours=${ANIMEPAHE_EPISODE_CACHE_HOURS:-6}
    [[ "$hours" =~ ^[0-9]+$ ]] || hours=6
    ttl=$(( hours * 3600 ))
    if [[ -s "$src" && -z "$force" && -z "$_REFRESH" ]]; then
        age=$(file_age "$src")
        if (( age < ttl )); then
            _EP_FROM_CACHE=1; _EP_CACHE_AGE=$age
            return 0
        fi
    fi
    _EP_FROM_CACHE=""
    while :; do
        ui_live "Fetching episode list (page $page/$last)…"
        if ! body=$(fetch_episode_page "$slug" "$page"); then failed=1; break; fi
        chunks+=("$("$_JQ" -c '.data' <<<"$body")")
        if (( page == 1 )); then last=$("$_JQ" -r '.last_page // 1' <<<"$body"); fi
        if (( page >= last )); then break; fi
        page=$(( page + 1 ))
        sleep 0.3
    done
    ui_live_clear
    if (( failed )); then
        if [[ -s "$src" ]]; then
            ui_warn "Could not refresh the episode list (page $page): $(curl_reason "${_LAST_CURL_RC:-0}")"
            ui_warn "Using the cached list — it may be out of date."
            _EP_FROM_CACHE=1; _EP_CACHE_AGE=$(file_age "$src")
            return 0
        fi
        die "Could not fetch the episode list (page $page): $(curl_reason "${_LAST_CURL_RC:-0}")"
    fi
    printf '%s\n' "${chunks[@]}" | "$_JQ" -s 'map(.[]) | {data: .}' >"$tmp" || { rm -f "$tmp"; die "Failed to combine episode data."; }
    mv -f "$tmp" "$src"
    _EP_CACHE_AGE=0
    mapfile -t _ALL_EPS < <("$_JQ" -r '.data[].episode' "$src" | sort -n -u)
}

load_episode_list() {
    local src="$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    mapfile -t _ALL_EPS < <("$_JQ" -r '.data[].episode' "$src" 2>/dev/null | sort -n -u)
    (( ${#_ALL_EPS[@]} > 0 )) || die "No episodes found for $_ANIME_NAME."
}

# ---------------------------------------------------------------------------
# Stream discovery
# ---------------------------------------------------------------------------
extract_stream_buttons() {
    printf '%s' "$1" | grep -oE '<button[^>]*data-av1="0"[^>]*>' || true
}

# stdout: "<res>\t<audio>\t<stream-url>"
get_episode_stream() {
    local num=$1 sid page rc=0 play_url tag res aud src pref o r rk a s sorted pick has_pref=""
    local src_file="$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    local re_res='data-resolution="([^"]+)"' re_aud='data-audio="([^"]+)"' re_src='data-src="([^"]+)"'
    local -a opts=() cands=() filt=()

    sid=$("$_JQ" -r --arg n "$num" 'first(.data[] | select((.episode | tostring) == $n) | .session) // empty' "$src_file" 2>/dev/null || true)
    if [[ -z "$sid" || ! "$sid" =~ ^[A-Za-z0-9_-]+$ ]]; then
        ui_row err "Stream" "episode $num not found in the episode list"
        return 1
    fi
    play_url="$_HOST/play/${_ANIME_SLUG}/${sid}"
    debug "play page: $play_url"
    page=$(http_get "$play_url") || rc=$?
    if (( rc != 0 )) || [[ -z "$page" ]]; then
        ui_row err "Stream" "could not load the play page: $(curl_reason "$rc")"
        return 1
    fi
    if [[ -n "$_DEBUG" ]]; then printf '%s' "$page" >"$_VIDEO_DIR_PATH/$_ANIME_NAME/play_page_ep${num}.html"; fi

    pref=${_ANIME_AUDIO:-eng}
    while IFS= read -r tag; do
        res=0 aud=unknown src=""
        if [[ "$tag" =~ $re_res ]]; then res=${BASH_REMATCH[1]}; fi
        if [[ "$tag" =~ $re_aud ]]; then aud=${BASH_REMATCH[1]}; fi
        if [[ "$tag" =~ $re_src ]]; then src=${BASH_REMATCH[1]}; fi
        [[ "$res" =~ ^[0-9]+$ ]] || res=0
        [[ -n "$src" ]] || continue
        rk=1; if [[ "$aud" == "$pref" ]]; then rk=0; has_pref=1; fi
        opts+=("$res"$'\t'"$rk"$'\t'"$aud"$'\t'"$src")
    done < <(extract_stream_buttons "$page")

    if (( ${#opts[@]} == 0 )); then
        ui_row err "Stream" "no usable (non-AV1) stream options on the play page"
        return 1
    fi
    cands=("${opts[@]}")

    if [[ -n "$_ANIME_AUDIO" ]]; then
        filt=()
        for o in "${cands[@]}"; do
            IFS=$'\t' read -r r rk a s <<<"$o"
            if [[ "$a" == "$_ANIME_AUDIO" ]]; then filt+=("$o"); fi
        done
        if (( ${#filt[@]} > 0 )); then
            cands=("${filt[@]}")
        else
            ui_warn "Audio '$_ANIME_AUDIO' is not offered; using what is available."
        fi
    fi
    if [[ -n "$_ANIME_RESOLUTION" ]]; then
        filt=()
        for o in "${cands[@]}"; do
            IFS=$'\t' read -r r rk a s <<<"$o"
            if [[ "$r" == "$_ANIME_RESOLUTION" ]]; then filt+=("$o"); fi
        done
        if (( ${#filt[@]} > 0 )); then
            cands=("${filt[@]}")
        else
            ui_warn "${_ANIME_RESOLUTION}p is not available; picking the best instead."
        fi
    fi

    sorted=$(printf '%s\n' "${cands[@]}" | sort -t$'\t' -k2,2n -k1,1nr)
    pick=${sorted%%$'\n'*}
    IFS=$'\t' read -r r rk a s <<<"$pick"
    debug "${#opts[@]} stream option(s) found"
    ui_row ok "Stream" "${r}p · ${a}"
    if [[ -z "$_ANIME_AUDIO" && -z "$has_pref" ]]; then ui_dim "no ${pref} audio offered for this episode; using ${a}"; fi
    printf '%s\t%s\t%s\n' "$r" "$a" "$s"
}

# Unpack kwik's packed JS with a JS runtime and extract the .m3u8 URL
get_playlist_link() { # kwik-url
    local stream_link=$1 page raw_js js_dir js_file js_out m3u8 rc=0
    local -a runner=()
    if [[ ! "$stream_link" =~ ^https://[^[:space:]]+$ ]]; then
        ui_row err "Playlist" "refusing to fetch a suspicious stream URL"
        return 1
    fi
    page=$(http_get "$stream_link") || rc=$?
    if (( rc != 0 )) || [[ -z "$page" ]]; then
        ui_row err "Playlist" "could not load the stream page: $(curl_reason "$rc" "$stream_link")"
        if (( rc == 22 )); then
            ui_dim "the host answered: $(curl_diag "$stream_link")"
            impersonation_hint
        fi
        return 1
    fi

    # Keep from "eval(" up to </script>; turn eval into console.log so the
    # unpacked code is printed instead of executed.
    raw_js=$(grep -m1 '<script>eval(' <<<"$page" \
        | sed -E -e 's/^.*<script>(eval\(.*)$/\1/' -e 's/<\/script>.*$//' \
                 -e 's/document/process/g' -e 's/querySelector/exit/g' -e 's/eval\(/console.log(/g' || true)
    if [[ -z "$raw_js" || "$raw_js" != 'console.log('* ]]; then
        ui_row err "Playlist" "packed JavaScript not found on the stream page"
        return 1
    fi
    if (( ${#raw_js} > 200000 )); then
        ui_row err "Playlist" "packed JavaScript is unexpectedly large (${#raw_js} bytes)"
        return 1
    fi

    js_dir=$("$_MKTEMP" -d "${TMPDIR:-/tmp}/animepahe-js.XXXXXX") || { ui_row err "Playlist" "cannot create a temp dir"; return 1; }
    js_file="$js_dir/unpack.js"
    printf '%s' "$raw_js" >"$js_file"
    runner=("${_JS_CMD[@]}")
    if [[ -n "$_TIMEOUT" ]]; then runner=("$_TIMEOUT" 15 "${runner[@]}"); fi
    js_out=$(env -i PATH="/usr/bin:/bin" "${runner[@]}" "$js_file" 2>/dev/null) || rc=$?
    rm -rf "$js_dir"
    if (( rc != 0 )); then
        ui_row err "Playlist" "$_JS_NAME failed or timed out while unpacking the stream page"
        return 1
    fi
    m3u8=$(grep -m1 'source=' <<<"$js_out" \
        | grep -oE "https://[^'\" ]+\.m3u8[^'\" ]*" | head -n 1 || true)
    if [[ -z "$m3u8" || "$m3u8" != https://*.m3u8* ]]; then
        ui_row err "Playlist" "no .m3u8 URL found after unpacking"
        return 1
    fi
    printf '%s\n' "$m3u8"
}

# ---------------------------------------------------------------------------
# Playlist → segments → decrypt → merge
# ---------------------------------------------------------------------------
parse_playlist() { # playlist-file playlist-url → _SEG_URLS/_SEG_FILES/_HLS_KEYLINE/_MEDIA_SEQ
    local plist=$1 base=$2 line i=0 first_key="" k distinct=0
    local -a keys=()
    _SEG_URLS=(); _SEG_FILES=(); _HLS_KEYLINE=""; _MEDIA_SEQ=0
    if grep -q '#EXT-X-STREAM-INF' "$plist"; then
        ui_row err "Playlist" "got a master playlist; a media playlist is required"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        case $line in
            '#EXT-X-KEY:'*)
                if [[ "$line" != *METHOD=NONE* ]]; then keys+=("$line"); fi
                continue ;;
            '#EXT-X-MEDIA-SEQUENCE:'*)
                _MEDIA_SEQ=${line#*:}
                [[ "$_MEDIA_SEQ" =~ ^[0-9]+$ ]] || _MEDIA_SEQ=0
                continue ;;
            ''|'#'*) continue ;;
        esac
        resolve_url "$base" "$line"
        _SEG_URLS+=("$_RESOLVED")
        segment_filename "$_RESOLVED" "$i"
        _SEG_FILES+=("$_WORKDIR/$_SEGNAME.encrypted")
        i=$(( i + 1 ))
    done <"$plist"
    if (( ${#_SEG_URLS[@]} == 0 )); then
        ui_row err "Playlist" "no segments found"
        return 1
    fi
    if (( ${#keys[@]} > 0 )); then
        first_key=${keys[0]}
        for k in "${keys[@]}"; do if [[ "$k" != "$first_key" ]]; then distinct=1; fi; done
        if (( distinct )); then
            ui_row err "Playlist" "key rotation is not supported"
            return 1
        fi
        if [[ "$first_key" != *METHOD=AES-128* ]]; then
            ui_row err "Playlist" "unsupported encryption method"
            return 1
        fi
        _HLS_KEYLINE=$first_key
    fi
}

download_segments() { # → 0 on success
    local total=${#_SEG_URLS[@]} i enc dec base=0 pending=0 rc=0 t0=$SECONDS
    local queue="$_WORKDIR/.queue" probe_url="" probe_enc="" reasons=""
    : >"$_WORKDIR/.done"; : >"$_WORKDIR/.failed"; : >"$queue"
    for i in "${!_SEG_URLS[@]}"; do
        enc=${_SEG_FILES[$i]}; dec=${enc%.encrypted}
        if [[ -s "$dec" || -s "$enc" ]]; then
            base=$(( base + 1 ))
        else
            if (( pending == 0 )); then probe_url=${_SEG_URLS[$i]}; probe_enc=$enc; fi
            printf '%s\0%s\0' "${_SEG_URLS[$i]}" "$enc" >>"$queue"
            pending=$(( pending + 1 ))
        fi
    done
    if (( base > 0 )); then ui_row skip "Resume" "$base of $total segments already on disk"; fi
    if (( pending > 0 )); then
        # Fetch one segment on its own first: an access problem (HTTP 403 ...) then
        # fails in seconds with a clear reason instead of after hundreds of retries.
        ui_live "Checking access to the video host…"
        if ! download_file "$probe_url" "$probe_enc" 2 2; then
            ui_live_clear
            _FALLBACK_OK=1
            if [[ "$_DL_CODE" == "0" ]]; then
                ui_row err "Downloading" "first segment failed: network error"
            else
                ui_row err "Downloading" "the video host refused the first segment (HTTP $_DL_CODE)"
                impersonation_hint
            fi
            return 1
        fi
        ui_live_clear
        export _WORKDIR _SEGMENT_REFERER
        export -f download_file segment_job
        progress_start "Downloading" "$total" "$base" "$_WORKDIR/.done"
        xargs -0 -n 2 -P "$_THREADS" bash -c 'segment_job "$1" "$2"' _ <"$queue" 2>/dev/null || rc=$?
        progress_stop
    fi
    rm -f "$queue"
    local have=0
    for enc in "${_SEG_FILES[@]}"; do
        if [[ -s "$enc" || -s "${enc%.encrypted}" ]]; then have=$(( have + 1 )); fi
    done
    if (( have != total )); then
        if [[ -s "$_WORKDIR/.failed" ]]; then
            reasons=$(awk '{c[$1]++} END {for (k in c) printf "%s%s x%d", (n++ ? ", " : ""), (k == "0" ? "network error" : "HTTP " k), c[k]}' "$_WORKDIR/.failed")
        fi
        ui_row err "Downloading" "$have/$total segments${reasons:+ ($reasons)} — re-run to resume"
        _FALLBACK_OK=1
        return 1
    fi
    ui_row ok "Downloaded" "$total segments in $(fmt_duration $(( SECONDS - t0 )))"
}

decrypt_segments() {
    local total=${#_SEG_FILES[@]} i enc dec kf="$_WORKDIR/mon.key" kurl key iv explicit="" pending=0 rc=0 t0=$SECONDS
    local re_uri='URI="([^"]+)"' re_iv='IV=0[xX]([0-9a-fA-F]+)'
    local queue="$_WORKDIR/.queue"

    if [[ -z "$_HLS_KEYLINE" ]]; then
        for enc in "${_SEG_FILES[@]}"; do
            dec=${enc%.encrypted}
            if [[ -s "$dec" ]]; then continue; fi
            if [[ -s "$enc" ]]; then
                mv -f "$enc" "$dec"
            else
                ui_row err "Segments" "missing $(basename "$enc")"; return 1
            fi
        done
        ui_row ok "Encryption" "none"
        return 0
    fi

    [[ "$_HLS_KEYLINE" =~ $re_uri ]] || { ui_row err "Decrypt" "key URI not found in playlist"; return 1; }
    resolve_url "$(<"$_WORKDIR/playlist.url")" "${BASH_REMATCH[1]}"
    kurl=$_RESOLVED
    if [[ ! "$kurl" =~ ^https?:// ]]; then ui_row err "Decrypt" "refusing non-http(s) key URI"; return 1; fi
    if [[ "$_HLS_KEYLINE" =~ $re_iv ]]; then explicit=${BASH_REMATCH[1]}; fi

    rm -f "$kf"
    download_file "$kurl" "$kf" 3 2 || { ui_row err "Decrypt" "could not download the decryption key"; return 1; }
    key=$(od -A n -t x1 "$kf" | tr -d ' \n')
    rm -f "$kf"
    [[ "$key" =~ ^[0-9a-fA-F]{32}$ ]] || { ui_row err "Decrypt" "key has an unexpected size/format"; return 1; }
    _HLS_KEY=$key

    : >"$_WORKDIR/.done"; : >"$_WORKDIR/.failed"; : >"$queue"
    local base=0
    for i in "${!_SEG_FILES[@]}"; do
        enc=${_SEG_FILES[$i]}; dec=${enc%.encrypted}
        if [[ -s "$dec" ]]; then base=$(( base + 1 )); continue; fi
        if [[ ! -s "$enc" ]]; then ui_row err "Decrypt" "missing $(basename "$enc")"; return 1; fi
        if [[ -n "$explicit" ]]; then
            iv=$explicit
            while (( ${#iv} < 32 )); do iv="0$iv"; done
        elif [[ "${ANIMEPAHE_HLS_SEQ_IV:-0}" == "1" ]]; then
            printf -v iv '%032x' $(( _MEDIA_SEQ + i ))
        else
            iv="00000000000000000000000000000000"
        fi
        printf '%s\0%s\0' "$enc" "$iv" >>"$queue"
        pending=$(( pending + 1 ))
    done
    if (( pending > 0 )); then
        export _WORKDIR _HLS_KEY
        export -f decrypt_job
        progress_start "Decrypting" "$total" "$base" "$_WORKDIR/.done"
        xargs -0 -n 2 -P "$_THREADS" bash -c 'decrypt_job "$1" "$2"' _ <"$queue" 2>/dev/null || rc=$?
        progress_stop
    fi
    rm -f "$queue"
    _HLS_KEY=""
    for enc in "${_SEG_FILES[@]}"; do
        if [[ ! -s "${enc%.encrypted}" ]]; then
            ui_row err "Decrypting" "failed (re-run to resume)"
            return 1
        fi
    done
    ui_row ok "Decrypted" "$total segments in $(fmt_duration $(( SECONDS - t0 )))"
}

generate_filelist() { # → $_WORKDIR/file.list (names relative to the list)
    local enc list="$_WORKDIR/file.list"
    : >"$list"
    for enc in "${_SEG_FILES[@]}"; do
        printf "file '%s'\n" "$(basename "${enc%.encrypted}")" >>"$list"
    done
    [[ -s "$list" ]] || { ui_row err "File list" "could not be generated"; return 1; }
}

merge_segments() { # output
    local v=$1 out_part="$1.part" err size
    ui_live "Merging with ffmpeg…"
    if ! err=$("$_FFMPEG" -hide_banner -loglevel error -f concat -safe 0 \
            -i "$_WORKDIR/file.list" -c copy -f mp4 -y "$out_part" 2>&1); then
        ui_live_clear
        rm -f "$out_part"
        ui_row err "Merging" "ffmpeg failed"
        printf '%s\n' "$err" | sed 's/^/      /' >&2
        return 1
    fi
    ui_live_clear
    mv -f "$out_part" "$v"
    size=$(du -h "$v" | cut -f1)
    ui_row ok "Merged" "$(basename "$v") · $size"
}

build_episode() { # num playlist-url output
    local num=$1 pl=$2 v=$3 plist sum
    _FALLBACK_OK=""
    _WORKDIR="$_VIDEO_DIR_PATH/$_ANIME_NAME/.work-ep${num}"
    if [[ -z "$_RESUME" ]]; then rm -rf "$_WORKDIR"; fi
    mkdir -p "$_WORKDIR" || { ui_row err "Workdir" "cannot create $_WORKDIR"; return 1; }
    plist="$_WORKDIR/playlist.m3u8"

    rm -f "$plist"
    if ! download_file "$pl" "$plist" 3 2; then
        ui_row err "Playlist" "could not download the playlist (HTTP ${_DL_CODE})"
        _FALLBACK_OK=1
        impersonation_hint
        return 1
    fi
    printf '%s\n' "$pl" >"$_WORKDIR/playlist.url"

    # A changed playlist invalidates any partial work
    sum=$(cksum <"$plist" | tr ' ' '-')
    if [[ -f "$_WORKDIR/playlist.sum" && "$(<"$_WORKDIR/playlist.sum")" != "$sum" ]]; then
        ui_row warn "Resume" "playlist changed on the server; starting over"
        find "$_WORKDIR" -mindepth 1 -maxdepth 1 ! -name playlist.m3u8 ! -name playlist.url -exec rm -rf {} +
    fi
    printf '%s\n' "$sum" >"$_WORKDIR/playlist.sum"

    parse_playlist "$plist" "$pl" || return 1
    ui_row ok "Playlist" "${#_SEG_URLS[@]} segments"

    download_segments || return 1
    set_title "🔑 $_ANIME_NAME - Episode $num - Decrypting"
    decrypt_segments || return 1
    generate_filelist || return 1
    set_title "🔗 $_ANIME_NAME - Episode $num - Merging"
    merge_segments "$v" || return 1
}

# Return codes: 0 downloaded, 10 already present, 1 failed
download_episode() {
    local num=$1 v stream_line res aud stream_link pl rc=0
    if [[ ! "$num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then ui_row err "Episode" "invalid episode number '$num'"; return 1; fi
    v="$_VIDEO_DIR_PATH/$_ANIME_NAME/${num}.mp4"
    if [[ -z "$_LIST_LINK_ONLY" && -s "$v" ]]; then
        ui_row skip "Skipped" "already downloaded (${num}.mp4)"
        return 10
    fi
    rm -f "$v" 2>/dev/null || true

    ui_live "Looking up stream…"
    stream_line=$(get_episode_stream "$num") || { ui_live_clear; return 1; }
    ui_live_clear
    # get_episode_stream already printed its own "Stream" row to stderr
    IFS=$'\t' read -r res aud stream_link <<<"$stream_line"
    # Referer for the video data = origin of the stream page (e.g. https://kwik.cx/)
    if [[ "$stream_link" =~ ^(https://[^/]+) ]]; then _SEGMENT_REFERER="${BASH_REMATCH[1]}/"; else _SEGMENT_REFERER=""; fi
    export _SEGMENT_REFERER

    ui_live "Unpacking stream page…"
    pl=$(get_playlist_link "$stream_link") || { ui_live_clear; return 1; }
    ui_live_clear

    if [[ -n "$_LIST_LINK_ONLY" ]]; then
        printf '%s\n' "$pl"
        return 0
    fi

    set_title "⏳ $_ANIME_NAME - Episode $num"
    _WORKDIR=""
    if [[ -n "$_USE_YTDLP" ]]; then
        ytdlp_download "$pl" "$v" || rc=1
    else
        build_episode "$num" "$pl" "$v" || rc=1
        if (( rc != 0 )) && [[ -n "$_FALLBACK_OK" && -n "$_YTDLP" ]]; then
            ui_row warn "Fallback" "the built-in downloader was refused; trying yt-dlp"
            rc=0
            ytdlp_download "$pl" "$v" || rc=1
        fi
    fi
    if (( rc != 0 )); then
        rm -f "$v" "$v.part"
        if [[ -z "$_WORKDIR" ]]; then
            :
        elif [[ -n "$_RESUME" ]]; then
            ui_dim "work files kept in .work-ep${num} — re-run the same command to resume"
        else
            rm -rf "$_WORKDIR"
        fi
        return 1
    fi
    if [[ -z "$_KEEP_WORKDIR" && -n "$_WORKDIR" ]]; then rm -rf "$_WORKDIR"; fi
    set_title "✅ $_ANIME_NAME - Episode $num - Finished"
    return 0
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
send_notification() {
    [[ -n "$_NOTIFY" && -n "$_NOTIFY_CMD" ]] || return 0
    "$_NOTIFY_CMD" -a "animepahe-dl" "$1" "$2" || true
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
ask_episodes() {
    local s
    if [[ -n "$_HEADLESS" ]]; then
        [[ -n "${ANIMEPAHE_EPISODES:-}" ]] || die "No episode selection. Use -e <selection> or ANIMEPAHE_EPISODES in headless mode."
        printf '%s' "$ANIMEPAHE_EPISODES"; return 0
    fi
    [[ -t 0 ]] || die "No episode selection and stdin is not a terminal. Use -e <selection>."
    _out "" >&2
    ui_dim "examples:  1   1-5   1,3,7   *   L3   F5   10-   *,!4"
    read -r -p "  Episodes › " s
    printf '%s' "$s"
}

print_summary() {
    local elapsed=$(( SECONDS - _T0 ))
    _IND="  "
    _out ""
    ui_rule
    _out "${BOLD}Summary${NC}"
    ui_row ok "Downloaded" "${#_OK_EPS[@]}$( ((${#_OK_EPS[@]})) && printf '  (%s)' "$(compact_ranges ', ' "${_OK_EPS[@]}")" )"
    if (( ${#_SKIP_EPS[@]} > 0 )); then
        ui_row skip "Skipped" "${#_SKIP_EPS[@]}  ($(compact_ranges ', ' "${_SKIP_EPS[@]}"))"
    fi
    if (( ${#_FAIL_EPS[@]} > 0 )); then
        ui_row err "Failed" "${#_FAIL_EPS[@]}  ($(compact_ranges ', ' "${_FAIL_EPS[@]}"))"
    fi
    ui_row info "Location" "$(tilde_path "$_VIDEO_DIR_PATH")/$_ANIME_NAME"
    ui_row info "Time" "$(fmt_duration "$elapsed")"
    if (( ${#_FAIL_EPS[@]} > 0 )); then
        _out ""
        _out "  ${DIM}Retry just the failed ones:${NC}"
        _out "    ${BOLD}${0##*/} -s $_ANIME_SLUG -e $(compact_ranges ',' "${_FAIL_EPS[@]}")${NC}"
    fi
    _out ""
}

download_episodes() {
    local e idx=0 total rc
    total=${#_SELECTED_EPS[@]}
    for e in "${_SELECTED_EPS[@]}"; do
        idx=$(( idx + 1 ))
        ui_section "Episode $e  ${DIM}($idx/$total)${NC}"
        rc=0
        download_episode "$e" || rc=$?
        case $rc in
            0)  _OK_EPS+=("$e") ;;
            10) _SKIP_EPS+=("$e") ;;
            *)  _FAIL_EPS+=("$e") ;;
        esac
    done
    if [[ -z "$_LIST_LINK_ONLY" ]]; then
        print_summary
        send_notification "Download finished: $_ANIME_NAME" \
            "Done: ${#_OK_EPS[@]}  Skipped: ${#_SKIP_EPS[@]}  Failed: ${#_FAIL_EPS[@]}"
    fi
    if (( ${#_FAIL_EPS[@]} > 0 )); then return 1; fi
}

main() {
    init_ui
    load_config
    apply_env_defaults
    parse_args "$@"
    init_ui
    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM

    ui_banner
    ui_section "Setup"
    set_var
    set_cookie
    if [[ -n "$_LOGIN" ]]; then
        browser_login
        if [[ -z "${_INPUT_ANIME_NAME}${_ANIME_SLUG}" ]]; then
            _out ""; return 0
        fi
    elif [[ "${ANIMEPAHE_USE_BROWSER:-0}" == "1" ]]; then
        ui_row info "Browser mode" "enabled in your config; opening a temporary browser"
        browser_login
    else
        preflight
    fi

    select_anime

    local dir="$_VIDEO_DIR_PATH/$_ANIME_NAME"
    ui_section "Episodes"
    download_source "$_ANIME_SLUG" "$dir"
    load_episode_list
    show_available_episodes

    if [[ -z "$_ANIME_EPISODE" ]]; then
        _ANIME_EPISODE=${ANIMEPAHE_EPISODES:-}
        if [[ -z "$_ANIME_EPISODE" ]]; then _ANIME_EPISODE=$(ask_episodes); fi
        [[ -n "$_ANIME_EPISODE" ]] || die "No episodes selected."
    fi
    select_episodes "$_ANIME_EPISODE" "$_EP_FROM_CACHE"
    # Asked for something the cached list doesn't have? A new episode may have aired.
    if [[ -n "$_EP_FROM_CACHE" ]] && (( _SEL_WARNINGS > 0 || ${#_SELECTED_EPS[@]} == 0 )); then
        ui_dim "the episode list is cached; checking for new episodes…"
        download_source "$_ANIME_SLUG" "$dir" force
        load_episode_list
        show_available_episodes
        select_episodes "$_ANIME_EPISODE"
    fi
    (( ${#_SELECTED_EPS[@]} > 0 )) || die "No episodes match '$_ANIME_EPISODE'."
    ui_row ok "Selected" "${#_SELECTED_EPS[@]}  ($(compact_ranges ', ' "${_SELECTED_EPS[@]}"))"

    download_episodes
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
