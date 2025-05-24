#!/usr/bin/env bash
#
# Download anime from animepahe in terminal
#
#/ Usage:
#/   ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-t <num>] [-l] [-d]
#/
#/ Options: 
#/   -a <name>               anime name
#/   -s <slug>               anime slug/uuid, can be found in $_ANIME_LIST_FILE
#/                           ignored when "-a" is enabled
#/   -e <num1,num3-num4...>  optional, episode number to download
#/                           multiple episode numbers seperated by ","
#/                           episode range using "-"
#/                           all episodes using "*"
#/   -r <resolution>         optional, specify resolution: "1080", "720"...
#/                           by default, the highest resolution is selected
#/   -o <language>           optional, specify audio language: "eng", "jpn"...
#/   -t <num>                optional, specify a positive integer as num of threads
#/   -l                      optional, show m3u8 playlist link without downloading videos
#/   -d                      enable debug mode
#/   -h | --help             display this help message

set -e
set -u

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check for terminal compatibility with colors
if ! [ -t 1 ]; then
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  PURPLE=''
  CYAN=''
  BOLD=''
  NC=''
fi

# --- Global Variables ---
_SCRIPT_NAME="$(basename "$0")"

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)"
    trap - EXIT # Unset the EXIT trap specifically for help
    exit 0
}

set_var() {
    _CURL="$(command -v curl)" || command_not_found "curl"
    _JQ="$(command -v jq)" || command_not_found "jq"
    _FZF="$(command -v fzf)" || command_not_found "fzf"
    if [[ -z ${ANIMEPAHE_DL_NODE:-} ]]; then
        _NODE="$(command -v node)" || command_not_found "node"
    else
        _NODE="$ANIMEPAHE_DL_NODE"
    fi
    _FFMPEG="$(command -v ffmpeg)" || command_not_found "ffmpeg"
    _OPENSSL="$(command -v openssl)" || command_not_found "openssl"
    _MKTEMP="$(command -v mktemp)" || command_not_found "mktemp"

    _HOST="https://animepahe.ru"
    _ANIME_URL="$_HOST/anime"
    _API_URL="$_HOST/api"
    _REFERER_URL="$_HOST"

    # --- MODIFIED/NEW ---
    _VIDEO_DIR_PATH="${ANIMEPAHE_VIDEO_DIR:-$HOME/Videos}"
    _ANIME_LIST_FILE="${ANIMEPAHE_LIST_FILE:-$_VIDEO_DIR_PATH/anime.list}"
    _SOURCE_FILE=".source.json" # This remains relative to the anime's own directory

    print_info "Ensuring video directory exists: ${BOLD}${_VIDEO_DIR_PATH}${NC}"
    mkdir -p "$_VIDEO_DIR_PATH" || print_error "Cannot create video directory: ${_VIDEO_DIR_PATH}"
    # --- END MODIFIED/NEW ---

    _SCRIPT_PATH=$(dirname "$(realpath "$0")")
}

set_args() {
    expr "$*" : ".*--help" > /dev/null && usage
    _PARALLEL_JOBS=1
    while getopts ":hlda:s:e:r:t:o:" opt; do
        case $opt in
            a)
                _INPUT_ANIME_NAME="$OPTARG"
                ;;
            s)
                _ANIME_SLUG="$OPTARG"
                ;;
            e)
                _ANIME_EPISODE="$OPTARG"
                ;;
            l)
                _LIST_LINK_ONLY=true
                ;;
            r)
                _ANIME_RESOLUTION="$OPTARG"
                ;;
            t)
                _PARALLEL_JOBS="$OPTARG"
                if [[ ! "$_PARALLEL_JOBS" =~ ^[0-9]+$ || "$_PARALLEL_JOBS" -eq 0 ]]; then
                    print_error "-t <num>: Number must be a positive integer"
                fi
                ;;
            o)
                _ANIME_AUDIO="$OPTARG"
                ;;
            d)
                _DEBUG_MODE=true
                set -x
                ;;
            h)
                usage
                ;;
            \?)
                print_error "Invalid option: -$OPTARG"
                ;;
        esac
    done
}

print_info() {
  # ℹ Symbol for info
  [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "${GREEN}ℹ ${NC}$1" >&2
}

print_warn() {
  # ⚠ Symbol for warning
  [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "${YELLOW}⚠ WARNING: ${NC}$1" >&2
}

print_error() {
  # ✘ Symbol for error
  printf "%b\n" "${RED}✘ ERROR: ${NC}$1" >&2
  exit 1
}

command_not_found() {
    # $1: command name
    print_error "$1 command not found! Please install it."
}

get() {
    # $1: url
    "$_CURL" -sS -L "$1" -H "cookie: $_COOKIE" --compressed
}

set_cookie() {
    local u
    u="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
    _COOKIE="__ddg2_=$u"
}

download_anime_list() {
    print_info "${YELLOW}⟳ Retrieving master anime list...${NC}"
    local content
    content=$(get "$_ANIME_URL") || {
        print_error "Failed getting master list from $_ANIME_URL"
        return 1
    }

    echo "$content" \
    | grep "/anime/" \
    | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' \
    > "$_ANIME_LIST_FILE"

    if [[ $? -eq 0 && -s "$_ANIME_LIST_FILE" ]]; then
        local count
        count=$(wc -l <"$_ANIME_LIST_FILE")
        print_info "${GREEN}✓ Successfully saved ${BOLD}$count${NC}${GREEN} titles to ${BOLD}$_ANIME_LIST_FILE${NC}"
    else
        rm -f "$_ANIME_LIST_FILE"
        print_error "Failed to parse or save master anime list."
    fi
}

search_anime_by_name() {
    # $1: anime name
    print_info "${YELLOW}⟳ Searching API for anime matching '${BOLD}$1${NC}'...${NC}"
    local d n query formatted_results
    query=$(printf %s "$1" | "$_JQ" -sRr @uri)
    d="$(get \"$_HOST/api?m=search&q=${query}\")"
    n="$\("$_JQ" -r '.total' <<< "$d"\)"

    if [[ "$n" == "null" || "$n" -eq "0" ]]; then
        print_warn "No results found via API for '$1'."
        echo ""
    else
        print_info "${GREEN}✓ Found ${BOLD}$n${NC}${GREEN} potential matches.${NC}"
        formatted_results="$\("$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d"\)"
        touch "$_ANIME_LIST_FILE"
        echo -e "$formatted_results" >> "$_ANIME_LIST_FILE"
        sort -u -o "$_ANIME_LIST_FILE"{,} "$_ANIME_LIST_FILE"
        echo -e "$formatted_results"
    fi
}

get_episode_list() {
    # $1: anime id
    # $2: page number
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"
}

download_source() {
    local d p n
    mkdir -p "$_VIDEO_DIR_PATH/$_ANIME_NAME"
    d="$(get_episode_list \"$_ANIME_SLUG\" \"1\")"
    p="$\("$_JQ" -r '.last_page' <<< "$d"\)"

    if [[ "$p" -gt "1" ]]; then
        for i in $(seq 2 "$p"); do
            n="$(get_episode_list \"$_ANIME_SLUG\" \"$i\")"
            d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
        done
    fi

    echo "$d" > "$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"
}

get_episode_link() {
    # $1: episode number
    local s o l r=""
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE")
    [[ "$s" == "" ]] && print_warn "Episode $1 not found!" && return
    o="$\("$_CURL" --compressed -sSL -H \"cookie: $_COOKIE\" \"${_HOST}/play/${_ANIME_SLUG}/${s}\"\)"
    l="$(grep <button <<< "$o" \
        | grep data-src \
        | sed -E 's/data-src="/\n/g' \
        | grep 'data-av1="0"')"

    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        print_info "Select audio language: $_ANIME_AUDIO"
        r="$(grep 'data-audio="'"$_ANIME_AUDIO"'"' <<< "$l")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected audio language is not available, fallback to default."
        fi
    fi

    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "Select video resolution: $_ANIME_RESOLUTION"
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "${r:-$l}")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected video resolution is not available, fallback to default"
        fi
    fi

    if [[ -z "${r:-}" ]]; then
        grep kwik <<< "$l" | tail -1 | grep kwik | awk -F '"' '{print $1}'
    else
        awk -F '" ' '{print $1}' <<< "$r" | tail -1
    fi
}

get_playlist_link() {
    # $1: episode link
    local s l
    s="$("$_CURL" --compressed -sS -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" "$1" \
        | grep "<script>eval(" \
        | awk -F 'script>' '{print $2}'\
        | sed -E 's/document/process/g' \
        | sed -E 's/querySelector/exit/g' \
        | sed -E 's/eval\(/console.log\(/g')"

    l="$("$_NODE" -e "$s" \
        | grep 'source=' \
        | sed -E "s/.m3u8';.*/.m3u8/" \
        | sed -E "s/.*const source='//")"

    echo "$l"
}

download_episodes() {
    # $1: episode number string
    local origel el uniqel
    origel=()
    if [[ "$1" == *","* ]]; then
        IFS="," read -ra ADDR <<< "$1"
        for n in "${ADDR[@]}"; do
            origel+=("$n")
        done
    else
        origel+=("$1")
    fi

    el=()
    for i in "${origel[@]}"; do
        if [[ "$i" == *"*"* ]]; then
            local eps fst lst
            eps="$("$_JQ" -r '.data[].episode' "$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE" | sort -nu)"
            fst="$(head -1 <<< "$eps")"
            lst="$(tail -1 <<< "$eps")"
            i="${fst}-${lst}"
        fi

        if [[ "$i" == *"-"* ]]; then
            s=$(awk -F '-' '{print $1}' <<< "$i")
            e=$(awk -F '-' '{print $2}' <<< "$i")
            for n in $(seq "$s" "$e"); do
                el+=("$n")
            done
        else
            el+=("$i")
        fi
    done

    IFS=" " read -ra uniqel <<< "$(printf '%s\n' "${el[@]}" | sort -n -u | tr '\n' ' ')"

    [[ ${#uniqel[@]} == 0 ]] && print_error "Wrong episode number!"

    for e in "${uniqel[@]}"; do
        download_episode "$e"
    done
}

get_thread_number() {
    # $1: playlist file
    local sn
    sn="$(grep -c "^https" "$1")"
    if [[ "$sn" -lt "$_PARALLEL_JOBS" ]]; then
        echo "$sn"
    else
        echo "$_PARALLEL_JOBS"
    fi
}

download_file() {
    # $1: URL link
    # $2: output file
    local s
    s=$("$_CURL" -sS -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" -C - "$1" -L -g -o "$2" \
        --connect-timeout 5 \
        --compressed \
        || echo "$?")
    if [[ "$s" -ne 0 ]]; then
        print_warn "Download was aborted. Retry..."
        download_file "$1" "$2"
    fi
}

decrypt_file() {
    # $1: input file
    # $2: encryption key in hex
    local of=${1%%.encrypted}
    "$_OPENSSL" aes-128-cbc -d -K "$2" -iv 0 -in "${1}" -out "${of}" 2>/dev/null
}

download_segments() {
    # $1: playlist file
    # $2: output path
    local op="$2"
    export _CURL _REFERER_URL op
    export -f download_file print_warn
    xargs -I {} -P "$(get_thread_number "$1")" \
        bash -c 'url="{}"; file="${url##*/}.encrypted"; download_file "$url" "${op}/${file}"' < <(grep "^https" "$1")
}

generate_filelist() {
    # $1: playlist file
    # $2: output file
    grep "^https" "$1" \
        | sed -E "s/https.*\//file '/" \
        | sed -E "s/$/'/" \
        > "$2"
}

decrypt_segments() {
    # $1: playlist file
    # $2: segment path
    local kf kl k
    kf="${2}/mon.key"
    kl=$(grep "#EXT-X-KEY:METHOD=" "$1" | awk -F '"' '{print $2}')
    download_file "$kl" "$kf"
    k="$(od -A n -t x1 "$kf" | tr -d ' \n')"

    export _OPENSSL k
    export -f decrypt_file
    xargs -I {} -P "$(get_thread_number "$1")" \
        bash -c 'decrypt_file "{}" "$k"' < <(ls "${2}/"*.encrypted)
}

# --- Trap Function ---
cleanup() {
    # Check if _VIDEO_DIR_PATH is set, otherwise we can't reliably find temp dirs
    if [[ -z "${_VIDEO_DIR_PATH:-}" ]]; then
        return
    fi
    local tmp_pattern_base="ep*_temp_${$}_XXXXXX"
    print_info "${YELLOW}ℹ Cleaning up temporary directories matching pattern ending with '.${$}.XXXXXX'...${NC}" >&2
    if [[ -n "${_ANIME_NAME:-}" && -d "$_VIDEO_DIR_PATH/$_ANIME_NAME" ]]; then
        find "$_VIDEO_DIR_PATH/$_ANIME_NAME" -maxdepth 1 -type d -name "$tmp_pattern_base" -prune -exec rm -rf {} + 2>/dev/null
    else
        find "$_VIDEO_DIR_PATH" -mindepth 2 -maxdepth 2 -type d -name "$tmp_pattern_base" -prune -exec rm -rf {} + 2>/dev/null
    fi
}

trap cleanup EXIT SIGINT SIGTERM

download_episode() {
    # $1: episode number
    local num="$1" l pl v erropt='' extpicky=''
    v="$_VIDEO_DIR_PATH/${_ANIME_NAME}/${num}.mp4"
    l=$(get_episode_link "$num")
    [[ "$l" != */* ]] && print_warn "Wrong download link or episode $1 not found!" && return
    pl=$(get_playlist_link "$l")
    [[ -z "${pl:-}" ]] && print_warn "Missing video list! Skip downloading!" && return
    if [[ -z ${_LIST_LINK_ONLY:-} ]]; then
        print_info "Downloading Episode $1..."
        [[ -z "${_DEBUG_MODE:-}" ]] && erropt="-v error"
        if ffmpeg -h full 2>/dev/null| grep extension_picky >/dev/null; then
            extpicky="-extension_picky 0"
        fi
        if [[ ${_PARALLEL_JOBS:-} -gt 1 ]]; then
            local opath plist cpath fname
            fname="file.list"
            cpath="$(pwd)"
            opath="$($_MKTEMP -d \"$_VIDEO_DIR_PATH/$_ANIME_NAME/ep${num}_temp_${$}_XXXXXX\")"
            if [[ ! -d "$opath" ]]; then
                print_warn "Failed to create temporary directory for episode $num."
                return 1
            fi
            print_info "  Created temporary directory: ${BOLD}$opath${NC}"
            plist="${opath}/playlist.m3u8"
            download_file "$pl" "$plist"
            print_info "Start parallel jobs with $(get_thread_number "$plist") threads"
            download_segments "$plist" "$opath"
            decrypt_segments "$plist" "$opath"
            generate_filelist "$plist" "${opath}/$fname"
            ! cd "$opath" && print_warn "Cannot change directory to $opath" && return
            "$_FFMPEG" $extpicky -f concat -safe 0 -i "$fname" -c copy $erropt -y "$v"
            ! cd "$cpath" && print_warn "Cannot change directory to $cpath" && return
        else
            "$_FFMPEG" $extpicky -headers "Referer: $_REFERER_URL" -i "$pl" -c copy $erropt -y "$v"
        fi
    else
        echo "$pl"
    fi
}

select_episodes_to_download() {
    [[ "$(grep 'data' -c \"$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE\")" -eq "0" ]] && print_error "No episode available!"
    "$_JQ" -r '.data[] | "[\(.episode | tonumber)] E\(.episode | tonumber) \(.created_at)"' "$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE" >&2
    echo -n "Which episode(s) to download: " >&2
    read -r s
    echo "$s"
}

remove_brackets() {
    awk -F']' '{print $1}' | sed -E 's/^\[//'
}

remove_slug() {
    awk -F'] ' '{print $2}'
}

get_slug_from_name() {
    # $1: anime name
    grep "] $1" "$_ANIME_LIST_FILE" | tail -1 | remove_brackets
}

main() {
    set_args "$@"
    set_var
    set_cookie

    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        local selected_line search_results
        search_results=$(search_anime_by_name "$__INPUT_ANIME_NAME")
        if [[ -z "$search_results" ]]; then
            print_error "No anime found matching '${_INPUT_ANIME_NAME}'."
        fi
        selected_line=$("$_FZF" -1 --exit-0 --delimiter='] ' --with-nth=2.. <<< "$search_results")
        if [[ -z "$selected_line" ]]; then
            print_error "No anime selected from search results."
        fi
        _ANIME_SLUG=$(echo "$selected_line" | remove_brackets)
        _ANIME_NAME=$(echo "$selected_line" | remove_slug | sed -E 's/[[:space:]]+$//')
    else
        download_anime_list
        if [[ -z "${_ANIME_SLUG:-}" ]]; then
            local selected_line
            selected_line=$("$_FZF" -1 --exit-0 --delimiter='] ' --with-nth=2.. < "$__ANIME_LIST_FILE")
            if [[ -z "$selected_line" ]]; then
                print_error "No anime selected from the list."
            fi
            _ANIME_SLUG=$(echo "$selected_line" | remove_brackets)
            _ANIME_NAME=$(echo "$selected_line" | remove_slug | sed -E 's/[[:space:]]+$//')
        fi
    fi
    [[ "$__ANIME_SLUG" == "" ]] && print_error "Anime slug not found!"
    _ANIME_NAME="$(grep "$__ANIME_SLUG" "$__ANIME_LIST_FILE" \
        | tail -1 \
        | remove_slug \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"
    if [[ "$__ANIME_NAME" == "" ]]; then
        print_warn "Anime name not found! Try again."
        download_anime_list
        exit 1
    fi
    download_source
    [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
    download_episodes "$__ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
