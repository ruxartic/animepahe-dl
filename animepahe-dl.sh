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
#/   -e <selection>          optional, episode selection string. Examples:
#/                           - Single: "1"
#/                           - Multiple: "1,3,5"
#/                           - Range: "1-5"
#/                           - All: "*"
#/                           - Exclude: "*,!1,!10-12" (all except 1 and 10-12)
#/                           - Latest N: "L3" (latest 3 available)
#/                           - First N: "F5" (first 5 available)
#/                           - From N: "10-" (episode 10 to last available)
#/                           - Up to N: "-5" (episode 1 to 5)
#/                           - Combined: "1-10,!5,L2" (1-10 except 5, plus latest 2)
#/   -r <resolution>         optional, specify resolution: "1080", "720"...
#/                           by default, the highest resolution is selected
#/   -o <language>           optional, specify audio language: "eng", "jpn"
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
                _DEBUG_MODE=1
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
    local num="$1"
    local session_id play_page_content play_url all_options
    local source_file_path="$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"

    print_info "  Looking up session ID for episode ${BOLD}$num${NC}..."
    session_id=$("$_JQ" -r --argjson num "$num" '.data[] | select(.episode == $num) | .session // empty' < "$source_file_path")

    if [[ -z "$session_id" ]]; then
        print_warn "Episode $num session ID not found in source file: $source_file_path"
        return 1
    fi

    play_url="${_HOST}/play/${_ANIME_SLUG}/${session_id}"
    print_info "  Fetching play page to find stream sources: ${BOLD}$play_url${NC}"
    play_page_content=$("$_CURL" --compressed -sSL --fail -H "cookie: $_COOKIE" -H "Referer: $_REFERER_URL" "$play_url")
    if [[ $? -ne 0 || -z "$play_page_content" ]]; then
        print_warn "Failed to fetch play page content for episode $num from $play_url."
        return 1
    fi
    [[ -n "${_DEBUG_MODE:-}" ]] && echo "$play_page_content" > "$_VIDEO_DIR_PATH/$_ANIME_NAME/play_page_ep${num}.html"

    print_info "  Extracting stream options (non-AV1) from play page..."
    all_options=$(echo "$play_page_content" |
        grep -oP '<button[^>]*data-av1="0"[^>]*>' |
        awk '{
            res="N/A"; aud="N/A"; src="N/A";
            if (match($0, /data-resolution="([^"]+)"/, r_match)) res=r_match[1];
            if (match($0, /data-audio="([^"]+)"/, a_match)) aud=a_match[1];
            if (match($0, /data-src="([^"]+)"/, s_match)) src=s_match[1];
            if (src != "N/A") print res, aud, src;
        }')

    if [[ -z "$all_options" ]]; then
        print_warn "No suitable stream options (non-AV1) found on play page for episode $num."
        return 1
    fi
    [[ -n "${_DEBUG_MODE:-}" ]] && echo -e "All non-AV1 options:\n$all_options" > "$_VIDEO_DIR_PATH/$_ANIME_NAME/stream_options_ep${num}.txt"

    local option_count
    option_count=$(echo "$all_options" | wc -l)
    print_info "    Found ${option_count} potential non-AV1 stream options."

    local candidates="$all_options"

    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        print_info "  Filtering for audio language: ${BOLD}${_ANIME_AUDIO}${NC}"
        local audio_filtered
        audio_filtered=$(echo "$candidates" | awk -v aud_pref="$_ANIME_AUDIO" '$2 == aud_pref')
        if [[ -z "$audio_filtered" ]]; then
            print_warn "Selected audio language '${_ANIME_AUDIO}' not available. Proceeding without this audio filter."
        else
            print_info "    ${GREEN}✓ Audio language filter applied. Matching options:${NC}\n$(echo "$audio_filtered" | sed 's/^/      /') "
            candidates="$audio_filtered"
        fi
    fi

    local final_choice=""
    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "  Attempting to select resolution: ${BOLD}${_ANIME_RESOLUTION}p${NC}"
        local res_filtered
        if [[ -n "$candidates" ]]; then
            res_filtered=$(echo "$candidates" | awk -v res_pref="$_ANIME_RESOLUTION" '$1 == res_pref')
        fi
        if [[ -z "$res_filtered" ]]; then
            print_warn "Selected resolution '${_ANIME_RESOLUTION}p' not available with current filters. Will pick best from remaining."
        else
            print_info "    ${GREEN}✓ Specific resolution found.${NC}"
            final_choice=$(echo "$res_filtered" | head -n 1)
        fi
    fi

    if [[ -z "$final_choice" ]]; then
        if [[ -z "$candidates" ]]; then
            print_warn "No stream options remain after filtering. Cannot select a link."
            return 1
        fi
        print_info "  Selecting highest available resolution from remaining candidates..."
        final_choice=$(echo "$candidates" | awk '{ if ($1 == "N/A") $1=0; print $0 }' | sort -k1,1nr -k2,2 | head -n 1)
    fi

    if [[ -z "$final_choice" ]]; then
        print_warn "Could not determine a final stream URL for episode $num after all filtering."
        return 1
    fi

    local final_res final_audio final_link
    read -r final_res final_audio final_link <<<"$final_choice"

    if [[ "$final_res" == "0" ]]; then final_res="N/A"; fi

    if [[ -z "$final_link" ]]; then
        print_warn "Failed to extract final URL from chosen option: [$final_choice]"
        return 1
    fi

    print_info "    ${GREEN}✓ Selected stream -> Res: ${final_res}p, Audio: ${final_audio}, Link: ${BOLD}$final_link${NC}"
    echo "$final_link"
    return 0
}

get_playlist_link() {
    # $1: episode stream link (e.g., kwik URL)
    local stream_link="$1"
    local page_content packed_js m3u8_url

    print_info "    Fetching stream page content from: ${BOLD}${stream_link}${NC}"
    page_content=$("$_CURL" --compressed -sS --fail -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" "$stream_link")
    if [[ $? -ne 0 || -z "$page_content" ]]; then
        print_warn "Failed to get stream page content from $stream_link"
        return 1
    fi

    print_info "    Extracting packed Javascript..."
    packed_js=$(echo "$page_content" |
        grep -oP "<script>eval\\(function\\(p,a,c,k,e,d\\).*?</script>" |
        head -n 1 |
        sed -e 's/<script>eval(//' -e 's/<\/script>$//' \
            -e 's/eval\*(.*)\/\*;.*$/console.log\1/' \
            -e 's/eval(function(p,a,c,k,e,d){[^}]*}([^;]*));/console.log\1/' \
            -e 's/document\\.getElementById\\([^)]+\\)\\.innerHTML\\s*=\\s*.*;//' \
            -e 's/document/process/g' \
            -e 's/querySelector/exit/g' \
            -e 's/eval\(/console.log\(/g'
    )

    if [[ -z "$packed_js" ]]; then
        print_warn "Could not extract packed JS block from stream page: $stream_link"
        [[ -n "${_DEBUG_MODE:-}" ]] && echo "$page_content" > "$_VIDEO_DIR_PATH/$_ANIME_NAME/stream_page_failed_js_extract.html"
        return 1
    fi

    print_info "    Executing JS with node.js to find m3u8 URL..."
    m3u8_url=$("$_NODE" -e "$packed_js" 2>/dev/null |
        grep -Eo "https://[a-zA-Z0-9./?=_%:-]*\.m3u8" |
        head -n 1
    )

    if [[ -z "$m3u8_url" || "$m3u8_url" != *.m3u8 ]]; then
        print_warn "Failed to extract m3u8 link using node.js from: $stream_link"
        [[ -n "${_DEBUG_MODE:-}" ]] && {
            echo "Packed JS fed to Node:" > "$_VIDEO_DIR_PATH/$_ANIME_NAME/packed_js_debug.js"
            echo "$packed_js" >> "$_VIDEO_DIR_PATH/$_ANIME_NAME/packed_js_debug.js"
            echo "Node output:" >> "$_VIDEO_DIR_PATH/$_ANIME_NAME/packed_js_debug.js"
            "$_NODE" -e "$packed_js" >> "$_VIDEO_DIR_PATH/$_ANIME_NAME/packed_js_debug.js" 2>&1
        }
        return 1
    fi

    print_info "    ${GREEN}✓ Found m3u8 playlist URL: ${BOLD}$m3u8_url${NC}"
    echo "$m3u8_url"
    return 0
}

download_episodes() {
    local ep_string="$1"
    local any_failures=0
    local source_path="$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    local all_available_eps=() include_list=() exclude_list=() final_list=()
    local total_selected=0 success_count=0 fail_count=0

    print_info "${YELLOW}⟳ Parsing episode selection string: ${BOLD}$ep_string${NC}"

    if [[ ! -f "$source_path" ]]; then
        print_error "Source file does not exist: $source_path"
    elif [[ ! -r "$source_path" ]]; then
        print_error "Source file is not readable: $source_path"
    fi

    mapfile -t all_available_eps < <("$_JQ" -r '.data[].episode' "$source_path" | sort -n)
    if [[ ${#all_available_eps[@]} -eq 0 ]]; then
        print_error "No available episodes found in source file: $source_path"
    fi
    local first_ep="${all_available_eps[0]}"
    local last_ep="${all_available_eps[-1]}"
    print_info "  Available episodes range from ${BOLD}$first_ep${NC} to ${BOLD}$last_ep${NC} (Total: ${#all_available_eps[@]})"

    IFS=',' read -ra input_parts <<<"$ep_string"

    for part in "${input_parts[@]}"; do
        part=$(echo "$part" | tr -d '[:space:]')
        part="${part#\"}"
        part="${part%\"}"
        local target_list_ref="include_list"
        local pattern="$part"

        if [[ "$pattern" == "!"* ]]; then
            target_list_ref="exclude_list"
            pattern="${pattern#!}"
            print_info "  Processing exclusion pattern: ${BOLD}$pattern${NC}"
        else
            print_info "  Processing inclusion pattern: ${BOLD}$pattern${NC}"
        fi

        case "$pattern" in
        \*)
            if [[ "$target_list_ref" == "include_list" ]]; then
                include_list+=("${all_available_eps[@]}")
            else
                exclude_list+=("${all_available_eps[@]}")
            fi
            ;;
        L[0-9]*)
            local num=${pattern#L}
            local temp_slice=()
            if [[ "$num" -gt 0 && "$num" -le ${#all_available_eps[@]} ]]; then
                temp_slice=("${all_available_eps[@]: -$num}")
            elif [[ "$num" -gt ${#all_available_eps[@]} ]]; then
                print_warn "  Requested latest $num, but only ${#all_available_eps[@]} available. Adding all."
                temp_slice=("${all_available_eps[@]}")
            else
                print_warn "  Invalid number for Latest N: $pattern. Must be > 0."
                continue
            fi
            if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("${temp_slice[@]}"); else exclude_list+=("${temp_slice[@]}"); fi
            ;;
        F[0-9]*)
            local num=${pattern#F}
            local temp_slice=()
            if [[ "$num" -gt 0 && "$num" -le ${#all_available_eps[@]} ]]; then
                temp_slice=("${all_available_eps[@]:0:$num}")
            elif [[ "$num" -gt ${#all_available_eps[@]} ]]; then
                print_warn "  Requested first $num, but only ${#all_available_eps[@]} available. Adding all."
                temp_slice=("${all_available_eps[@]}")
            else
                print_warn "  Invalid number for First N: $pattern. Must be > 0."
                continue
            fi
            if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("${temp_slice[@]}"); else exclude_list+=("${temp_slice[@]}"); fi
            ;;
        [0-9]*-)
            local start_num=${pattern%-}
            for ep_val in "${all_available_eps[@]}"; do
                if (( ep_val >= start_num )); then
                    if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("$ep_val"); else exclude_list+=("$ep_val"); fi
                fi
            done
            ;;
        -[0-9]*)
            local end_num=${pattern#-}
            for ep_val in "${all_available_eps[@]}"; do
                if (( ep_val <= end_num )); then
                   if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("$ep_val"); else exclude_list+=("$ep_val"); fi
                fi
            done
            ;;
        [0-9]*-[0-9]*)
            local s e
            s=$(awk -F '-' '{print $1}' <<<"$pattern")
            e=$(awk -F '-' '{print $2}' <<<"$pattern")
            if [[ ! "$s" =~ ^[0-9]+$ || ! "$e" =~ ^[0-9]+$ ]] || ((s > e)); then
                print_warn "  Invalid range '$pattern'. Skipping."
                continue
            fi
            for ep_val in "${all_available_eps[@]}"; do
                if (( ep_val >= s && ep_val <= e )); then
                    if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("$ep_val"); else exclude_list+=("$ep_val"); fi
                fi
            done
            ;;
        [0-9]*)
            local found_in_available=0
            for ep_val in "${all_available_eps[@]}"; do
                if [[ "$ep_val" == "$pattern" ]]; then
                    if [[ "$target_list_ref" == "include_list" ]]; then include_list+=("$pattern"); else exclude_list+=("$pattern"); fi
                    found_in_available=1
                    break
                fi
            done
            [[ $found_in_available -eq 0 ]] && print_warn "  Episode $pattern specified but not found in available episode list."
            ;;
        *)
            print_warn "  Unrecognized pattern '$pattern'. Skipping."
            ;;
        esac
    done

    local unique_includes=() unique_excludes=() temp_final_list=()
    mapfile -t unique_includes < <(printf '%s\n' "${include_list[@]}" | sort -n -u)
    mapfile -t unique_excludes < <(printf '%s\n' "${exclude_list[@]}" | sort -n -u)

    print_info "  Processed ${#unique_includes[@]} unique include directives and ${#unique_excludes[@]} unique exclude directives."

    for item in "${unique_includes[@]}"; do
        local is_excluded=0
        for ex_item in "${unique_excludes[@]}"; do
            if [[ "$item" == "$ex_item" ]]; then
                is_excluded=1
                break
            fi
        done
        if [[ $is_excluded -eq 0 ]]; then
            temp_final_list+=("$item")
        fi
    done
    final_list=("${temp_final_list[@]}")
    total_selected=${#final_list[@]}

    if [[ $total_selected -eq 0 ]]; then
        if [[ ${#unique_includes[@]} -eq 0 && "$ep_string" != "!"* ]]; then
            print_error "No episodes selected. Please check your selection string: '$ep_string'"
        else
            print_warn "No episodes remaining after applying all inclusion/exclusion rules for: '$ep_string'"
            exit 0
        fi
    fi

    print_info "${GREEN}✓ Final Download Plan:${NC} ${BOLD}${total_selected}${NC} unique episode(s) -> ${final_list[*]}"
    echo

    local current_ep_idx=0
    for e_num in "${final_list[@]}"; do
        current_ep_idx=$((current_ep_idx + 1))
        echo -e "${PURPLE}--- [ Processing Episode ${BOLD}$e_num${NC} (${current_ep_idx}/${total_selected}) ] ---${NC}"
        if download_episode "$e_num"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            any_failures=1
            print_warn "Episode ${BOLD}$e_num${NC} failed or was skipped. Continuing..."
        fi
        echo
    done

    echo -e "\n${BOLD}${CYAN}======= Download Summary =======${NC}"
    echo -e "${GREEN}✓ Successfully processed: ${BOLD}$success_count${NC}${GREEN} episode(s)${NC}"
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${RED}✘ Failed/Skipped:       ${BOLD}$fail_count${NC}${RED} episode(s)${NC}"
    fi
    echo -e "${BLUE}Total selected:       ${BOLD}$total_selected${NC}${BLUE} episode(s)${NC}"
    echo -e "${GREEN}✓ All planned tasks completed.${NC}\n"

    exit $any_failures
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
    echo -e -n "\n${YELLOW}▶ Which episode(s) to download?${NC} (e.g., 1, 3-5, *, L2, !6): " >&2
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
    [[ -z "${_ANIME_EPISODE}" ]] && print_error "No episodes selected for download."
    download_episodes "$__ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
