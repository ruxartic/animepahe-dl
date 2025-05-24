#!/usr/bin/env bash
#
# Download anime from animepahe in terminal
#
#/ Usage:
#/   ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-t <num>] [-T <secs>] [-l] [-d]
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
#/   -t <num>                optional, specify a positive integer as num of threads (default: 4)
#/   -T <secs>               optional, add timeout in seconds for individual segment download jobs.
#/                           Requires GNU Parallel.
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
_ANIME_NAME="unknown_anime" # Default, will be overwritten
_ALLOW_NOTIFICATION="${ANIMEPAHE_DOWNLOAD_NOTIFICATION:-false}"
_NOTIFICATION_URG="normal"

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)"
    trap - EXIT # Unset the EXIT trap specifically for help
    exit 0
}

set_var() {
    print_info "Checking required tools..."
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
    _PARALLEL="$(command -v parallel)" || command_not_found "parallel (GNU Parallel)"
    _NOTIFICATION_CMD="$(command -v notify-send)" || print_warn "notify-send command not found, desktop notifications will be disabled."
    print_info "${GREEN}✓ All essential tools checked.${NC}"

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
}

set_args() {
    expr "$*" : ".*--help" > /dev/null && usage
    _PARALLEL_JOBS=4
    while getopts ":hlda:s:e:r:t:o:T:" opt; do
        case $opt in
            a) _INPUT_ANIME_NAME="$OPTARG" ;;
            s) _ANIME_SLUG="$OPTARG" ;;
            e) _ANIME_EPISODE="$OPTARG" ;;
            l) _LIST_LINK_ONLY=true ;;
            r) _ANIME_RESOLUTION="$OPTARG" ;;
            t)
                _PARALLEL_JOBS="$OPTARG"
                if [[ ! "$_PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "-t <num>: Number must be a positive integer."
                fi
                ;;
            o) _ANIME_AUDIO="$OPTARG" ;;
            T)
                _SEGMENT_TIMEOUT="$OPTARG"
                if [[ ! "$_SEGMENT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "-T <secs>: Timeout must be a positive integer (seconds)."
                fi
                print_info "${YELLOW}Segment download job timeout set to: ${_SEGMENT_TIMEOUT}s${NC}"
                ;;
            d)
                _DEBUG_MODE=true
                print_info "${YELLOW}Debug mode enabled.${NC}"
                set -x
                ;;
            h) usage ;;
            \?) print_error "Invalid option: -$OPTARG" ;;
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
    # Uses curl with error checking. --fail makes curl exit non-zero on HTTP errors.
    local output
    output="$($_CURL -sS -L --fail "$1" -H "cookie: $_COOKIE" --compressed)"
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    echo "$output"
}

set_cookie() {
    local u
    u="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
    _COOKIE="__ddg2_=$u"
    print_info "Set temporary session cookie."
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
    local anime_slug="$1"
    local anime_name_for_path="$2"
    local source_path="$_VIDEO_DIR_PATH/$anime_name_for_path/$_SOURCE_FILE"
    print_info "${YELLOW}⟳ Downloading episode list for ${BOLD}$anime_name_for_path${NC}...${NC}"
    mkdir -p "$_VIDEO_DIR_PATH/$anime_name_for_path" || print_error "Cannot create directory: $_VIDEO_DIR_PATH/$anime_name_for_path"
    local d current_page=1 last_page
    local json_data_parts=()
    set_title "⟳ Src: $anime_name_for_path"
    while true; do
        print_info "  Fetching episode page ${BOLD}$current_page${NC}..."
        d=$(get_episode_list "$anime_slug" "$current_page")
        if [[ $? -ne 0 || -z "$d" || "$d" == "null" ]]; then
            if [[ $current_page -eq 1 ]]; then
                print_error "Failed to get first page of episode list for $anime_name_for_path."
            else
                print_warn "Failed to get page $current_page for $anime_name_for_path. Proceeding with previously downloaded data."
                break
            fi
        fi
        if ! echo "$d" | "$_JQ" -e '.data and .last_page' > /dev/null; then
            if [[ $current_page -eq 1 ]]; then
                print_error "Invalid data structure received on first page for $anime_name_for_path."
            else
                print_warn "Invalid data structure on page $current_page for $anime_name_for_path. Proceeding with data so far."
                break
            fi
        fi
        json_data_parts+=("$(echo "$d" | "$_JQ" -c '.data')")
        last_page=$("$_JQ" -r '.last_page // 1' <<< "$d")
        if (( current_page >= last_page )); then
            break
        fi
        current_page=$((current_page + 1))
        sleep 0.3
    done
    if [[ ${#json_data_parts[@]} -eq 0 ]]; then
        print_error "No episode data could be fetched for $anime_name_for_path."
    fi
    local combined_json_data_array
    combined_json_data_array=$(printf '%s\n' "${json_data_parts[@]}" | "$_JQ" -s 'add')
    local final_json_object
    final_json_object=$(echo "$combined_json_data_array" | "$_JQ" '{data: .}')
    echo "$final_json_object" > "$source_path"
    if [[ $? -eq 0 && -s "$source_path" ]]; then
        local ep_count
        ep_count=$(echo "$final_json_object" | "$_JQ" -r '.data | length')
        print_info "${GREEN}✓ Successfully downloaded source info for ${BOLD}$ep_count${NC}${GREEN} episodes to ${BOLD}$source_path${NC}"
    else
        rm -f "$source_path"
        print_error "Failed to save combined episode source file to $source_path."
    fi
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
    echo -e "${BLUE}Total planned:        ${BOLD}$total_selected${NC}${BLUE} episode(s)${NC}"
    echo
    echo -e "${GREEN}✓ All tasks completed!${NC}"
    local notif_title="Download complete: $_ANIME_NAME"
    local notif_body="Success: $success_count episode(s). "
    if [[ $fail_count -gt 0 ]]; then
        notif_body+="Failed: $fail_count episode(s)."
    fi
    send_notification "$notif_title" "$notif_body"
    exit $any_failures
}

download_file() {
    # ARG 1: URL ($1)
    # ARG 2: Outfile ($2) - THIS IS THE FULL PATH TO SAVE TO
    # ARG 3: MaxRetries ($3, optional, default 3)
    # ARG 4: InitialDelay ($4, optional, default 2)

    local url="$1"
    local outfile="$2"
    local max_retries=${3:-3}
    local initial_delay=${4:-2}
    local attempt=0 delay=$initial_delay curl_exit_code=0

    local display_filename
    display_filename=$(basename "$outfile")

    mkdir -p "$(dirname "$outfile")" || {
        print_warn "      Failed to create directory for $display_filename: $(dirname "$outfile")"
        return 1
    }

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        local curl_stderr
        curl_stderr=$({
            "$_CURL" --fail -sS -L -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" \
                -C - "$url" \
                --connect-timeout 10 \
                --retry 2 --retry-delay 1 \
                --compressed \
                -o "$outfile"
            curl_exit_code=$?
        } 2>&1 >/dev/null)

        if [[ "$curl_exit_code" -eq 0 ]]; then
            if [[ -s "$outfile" ]]; then
                return 0
            else
                print_warn "      Download of ${BOLD}$display_filename${NC} (curl code 0) but output file is empty/missing. Will retry."
                curl_exit_code=99
            fi
        fi

        if [[ $attempt -lt $max_retries ]]; then
            print_warn "      Download attempt $attempt/$max_retries failed for ${BOLD}$display_filename${NC} (curl code: $curl_exit_code). Retrying in $delay seconds..."
        fi
        rm -f "$outfile"
        sleep "$delay"
        delay=$((delay * 2))
    done

    print_warn "Download failed for ${BOLD}$display_filename${NC} after $max_retries attempts (URL: $url)."
    rm -f "$outfile"
    return 1
}

decrypt_file() {
    # $1: input file
    # $2: encryption key in hex
    local of=${1%%.encrypted}
    "$_OPENSSL" aes-128-cbc -d -K "$2" -iv 0 -in "${1}" -out "${of}" 2>/dev/null
}

download_segments() {
    # $1: playlist_file (full path to the downloaded m3u8 for the episode)
    # $2: output_path (full path to the temporary directory for this episode's segments)
    local playlist_file="$1"
    local output_path="$2"
    local segment_urls=()
    local retval=0

    mapfile -t segment_urls < <(grep "^https" "$playlist_file")
    local total_segments=${#segment_urls[@]}

    if [[ $total_segments -eq 0 ]]; then
        print_warn "No segment URLs found in playlist: $playlist_file"
        return 1
    fi

    local num_threads="$_PARALLEL_JOBS"
    print_info "  Downloading ${BOLD}$total_segments${NC} segments using ${BOLD}$num_threads${NC} thread(s) via GNU Parallel."

    local parallel_opts=()
    parallel_opts+=("--jobs" "$num_threads")
    parallel_opts+=("--bar")
    parallel_opts+=("--eta")
    parallel_opts+=("--tag")

    if [[ -n "${_SEGMENT_TIMEOUT:-}" ]]; then
        print_info "    (Individual download job timeout: ${_SEGMENT_TIMEOUT}s)"
        parallel_opts+=("--timeout" "${_SEGMENT_TIMEOUT}s")
    fi

    export -f download_file print_info print_warn
    export _CURL _REFERER_URL _COOKIE

    printf '%s\n' "${segment_urls[@]}" |
        "$_PARALLEL" "${parallel_opts[@]}" \
            download_file {} "${output_path}/{/}.encrypted"

    local parallel_status=$?

    local downloaded_count
    downloaded_count=$(find "$output_path" -maxdepth 1 -type f -name '*.encrypted' -print 2>/dev/null | wc -l)

    if [[ "$downloaded_count" -ne "$total_segments" ]]; then
        [[ $retval -eq 0 ]] && print_warn "Segment count mismatch. Expected $total_segments, found $downloaded_count in $output_path."
        retval=1
    elif [[ $retval -eq 0 ]]; then
        print_info "  ${GREEN}✓ All ${total_segments} segments appear to be downloaded (GNU Parallel finished).${NC}"
    fi

    if [[ $retval -ne 0 ]]; then
        print_warn "  Segment download phase failed or incomplete. Downloaded: $downloaded_count / Expected: $total_segments."
    fi

    return $retval
}

generate_filelist() {
    # $1: playlist_file (source for segment names, e.g., ${opath}/playlist.m3u8)
    # $2: output_file_list_path (e.g., ${opath}/file.list)
    local playlist_file="$1"
    local output_file_list_path="$2"
    local temp_dir_path
    temp_dir_path=$(dirname "$output_file_list_path")
    print_info "  Generating file list for ffmpeg: $output_file_list_path"
    grep "^https" "$playlist_file" |
        sed -E "s/^https.*\///" |
        sed -E 's/(\.(ts|m4s|mp4|aac|jpg))(\?.*|#.*)?$/\1/' |
        sed -E "s/^/file '/" |
        sed -E "s/$/'/" > "$output_file_list_path"
    if [[ ! -s "$output_file_list_path" ]]; then
        print_warn "Failed to generate or generated empty file list: $output_file_list_path"
        return 1
    fi
    local missing_segment_files=0
    while IFS= read -r line; do
        local segment_filename="${line#file '}"
        segment_filename="${segment_filename%'}"
        if [[ ! -f "${temp_dir_path}/${segment_filename}" ]]; then
            print_warn "    File listed in $(basename "$output_file_list_path") not found on disk: ${temp_dir_path}/${segment_filename}"
            missing_segment_files=$((missing_segment_files + 1))
        fi
    done < "$output_file_list_path"
    if [[ $missing_segment_files -gt 0 ]]; then
        print_warn "$missing_segment_files segment file(s) listed in $(basename "$output_file_list_path") are missing. Concatenation will likely fail."
    fi
    print_info "  ${GREEN}✓ File list generated and segment existence checked: ${BOLD}$(basename "$output_file_list_path")${NC}"
    return 0
}

decrypt_segments() {
    # $1: playlist_file (full path)
    # $2: segment_path (temporary directory for this episode)
    # $3: num_threads (passed from download_episode)
    local playlist_file="$1"
    local segment_path="$2"
    local num_threads="$3"
    local kf kl k encrypted_files_list=() total_encrypted retval=0

    kf="${segment_path}/mon.key"
    print_info "  Checking playlist for encryption key: $playlist_file"
    kl=$(grep "#EXT-X-KEY:METHOD=AES-128" "$playlist_file" | head -n 1 | awk -F 'URI="' '{print $2}' | awk -F '"' '{print $1}')

    if [[ -z "$kl" ]]; then
        print_info "  Playlist indicates stream is not encrypted. Skipping decryption."
        mapfile -t encrypted_files_list < <(find "$segment_path" -maxdepth 1 -type f -name '*.encrypted' -print 2>/dev/null)
        if [[ ${#encrypted_files_list[@]} -gt 0 ]]; then
            print_warn "    Playlist shows no encryption, but ${#encrypted_files_list[@]} *.encrypted files found! Check playlist/downloads."
        fi
        return 0
    fi

    print_info "  Stream appears encrypted. Downloading decryption key: ${BOLD}$kl${NC}"
    if ! download_file "$kl" "$kf" 3 2; then
        print_warn "Failed to download encryption key: $kl from $kf"
        return 1
    fi

    k="$(od -A n -t x1 "$kf" | tr -d '[: \n]')"
    if [[ -z "$k" ]]; then
        print_warn "Failed to extract encryption key hex from $kf."
        rm -f "$kf"
        return 1
    fi

    mapfile -t encrypted_files_list < <(find "$segment_path" -maxdepth 1 -type f -name '*.encrypted' -print)
    total_encrypted=${#encrypted_files_list[@]}

    if [[ $total_encrypted -eq 0 ]]; then
        print_warn "No *.encrypted files found to decrypt in $segment_path, though playlist specified a key."
        rm -f "$kf"
        return 0
    fi

    print_info "  Decrypting ${BOLD}$total_encrypted${NC} segments using ${BOLD}$num_threads${NC} thread(s) via GNU Parallel..."
    export -f decrypt_file print_warn
    export _OPENSSL

    local parallel_opts_decrypt=()
    parallel_opts_decrypt+=("--jobs" "$num_threads")
    parallel_opts_decrypt+=("--tag")

    printf '%s\n' "${encrypted_files_list[@]}" |
        "$_PARALLEL" "${parallel_opts_decrypt[@]}" \
            decrypt_file {} "$k"

    local parallel_decrypt_status=$?

    local decrypted_count
    decrypted_count=$(find "$segment_path" -maxdepth 1 -type f ! -name '*.encrypted' ! -name 'mon.key' ! -name 'playlist.m3u8' ! -name 'file.list' -print 2>/dev/null | wc -l)

    if [[ "$decrypted_count" -ne "$total_encrypted" ]]; then
        [[ $retval -eq 0 ]] && print_warn "Decrypted file count mismatch. Expected $total_encrypted, found $decrypted_count."
        retval=1
    elif [[ $retval -eq 0 ]]; then
        print_info "  ${GREEN}✓ All ${total_encrypted} segments appear to be decrypted.${NC}"
    fi

    if [[ -z "${_DEBUG_MODE:-}" ]]; then
        print_info "  Cleaning up key file: $kf"
        rm -f "$kf"
        if [[ $retval -eq 0 ]]; then
            print_info "  Cleaning up ${total_encrypted} encrypted segment files..."
            printf '%s\n' "${encrypted_files_list[@]}" | "$_PARALLEL" --jobs "$num_threads" rm -f {}
        else
            print_warn "  Encrypted files not removed due to decryption errors."
        fi
    else
        print_warn "Debug mode: Leaving key file $kf and encrypted segments."
    fi
    return $retval
}

# --- Trap Function ---
cleanup() {
    if [[ -z "${_VIDEO_DIR_PATH:-}" ]]; then
        return
    fi
    local tmp_pattern_base="ep*_temp_${$}_XXXXXX"
    print_info "${YELLOW}ℹ Global cleanup: Removing temporary directories matching '...${$}.XXXXXX'...${NC}" >&2
    if [[ -n "${_ANIME_NAME:-}" && -d "$_VIDEO_DIR_PATH/$_ANIME_NAME" ]]; then
        find "$_VIDEO_DIR_PATH/$_ANIME_NAME" -maxdepth 1 -type d -name "$tmp_pattern_base" -prune -exec rm -rf {} + 2>/dev/null
    else
        find "$_VIDEO_DIR_PATH" -mindepth 1 -maxdepth 2 -type d -name "$tmp_pattern_base" -prune -exec rm -rf {} + 2>/dev/null
    fi
}
trap cleanup EXIT SIGINT SIGTERM

set_title() {
    if [[ -t 1 && -z "${_LIST_LINK_ONLY:-}" ]]; then
        local title="$1"
        printf "\033]0;%s\007" "$title"
    fi
}

send_notification() {
    if ! command -v "$_NOTIFICATION_CMD" &> /dev/null || [[ "${_ALLOW_NOTIFICATION}" != "true" ]]; then
        return 0
    fi
    local title="${1}"
    local body="${2}"
    local urgency="${3:-$_NOTIFICATION_URG}"
    "$_NOTIFICATION_CMD" -u "$urgency" -i "folder-download-symbolic" -a "$SCRIPT_NAME" "$title" "$body" \
        || print_warn "Failed to send notification."
}

sanitize_filename() {
    echo "$1" | sed -E \
        -e 's/[^[:alnum:] ,+\-\)\(._]/_/g' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//'
}

download_episode() {
    local num="$1"
    local v target_video_path
    local stream_page_link
    local m3u8_playlist_url
    local ffmpeg_error_opt="-v error"
    local ffmpeg_ext_picky_opt=""
    local temp_dir_path plist_in_temp current_dir fname_in_temp num_threads
    local retval=0
    target_video_path="$_VIDEO_DIR_PATH/$_ANIME_NAME/${num}.mp4"
    if [[ -f "$target_video_path" ]]; then
        print_info "${GREEN}✓ Episode ${BOLD}$num ($target_video_path)${NC}${GREEN} already exists. Skipping.${NC}"
        set_title "✓ Ep $num (Exists) - $_ANIME_NAME"
        return 0
    fi
    print_info "Processing Episode ${BOLD}$num${NC}:"
    set_title "⏳ Ep $num Link - $_ANIME_NAME"
    stream_page_link=$(get_episode_link "$num") || { retval=1; print_warn "Failed to get stream page link for ep $num."; return 1; }
    print_info "  Found stream page link: ${BOLD}$stream_page_link${NC}"
    m3u8_playlist_url=$(get_playlist_link "$stream_page_link") || { retval=1; print_warn "Failed to get m3u8 playlist URL for ep $num."; return 1; }
    print_info "  Found m3u8 playlist URL: ${BOLD}$m3u8_playlist_url${NC}"
    if [[ -n "${_LIST_LINK_ONLY:-}" ]]; then
        echo "$m3u8_playlist_url"
        return 0
    fi
    print_info "Starting download process for Episode ${BOLD}$num${NC}..."
    set_title "⏳ Ep $num Prep - $_ANIME_NAME"
    [[ -z "${_DEBUG_MODE:-}" ]] || ffmpeg_error_opt=""
    if ffmpeg -h full 2>/dev/null | grep -q "extension_picky"; then
        ffmpeg_ext_picky_opt="-extension_picky 0"
    fi
    fname_in_temp="file.list"
    current_dir="$(pwd)"
    num_threads="$_PARALLEL_JOBS"
    temp_dir_path=$("$_MKTEMP" -d "$_VIDEO_DIR_PATH/$_ANIME_NAME/ep${num}_temp_${$}_XXXXXX")
    if [[ ! -d "$temp_dir_path" ]]; then
        print_warn "Failed to create temporary directory for episode $num."
        return 1
    fi
    print_info "  Created temporary directory: ${BOLD}$temp_dir_path${NC}"
    plist_in_temp="${temp_dir_path}/playlist.m3u8"
    print_info "  ${CYAN}--- Master Playlist Download ---${NC}"
    set_title "📜 Ep $num Playlist - $_ANIME_NAME"
    download_file "$m3u8_playlist_url" "$plist_in_temp" 3 2 || retval=1
    if [[ $retval -eq 0 ]]; then
        print_info "  ${CYAN}--- Segment Download Phase ---${NC}"
        set_title "📥 Ep $num Segments - $_ANIME_NAME"
        download_segments "$plist_in_temp" "$temp_dir_path" || retval=1
    fi
    if [[ $retval -eq 0 ]]; then
        print_info "  ${CYAN}--- Segment Decryption Phase ---${NC}"
        set_title "🔑 Ep $num Decrypt - $_ANIME_NAME"
        decrypt_segments "$plist_in_temp" "$temp_dir_path" "$num_threads" || retval=1
    fi
    if [[ $retval -eq 0 ]]; then
        print_info "  ${CYAN}--- File List Generation ---${NC}"
        set_title "📄 Ep $num Filelist - $_ANIME_NAME"
        generate_filelist "$plist_in_temp" "${temp_dir_path}/$fname_in_temp" || retval=1
    fi
    if [[ $retval -eq 0 ]]; then
        print_info "  ${CYAN}--- Concatenation Phase ---${NC}"
        set_title "🔗 Ep $num Concat - $_ANIME_NAME"
        print_info "  Running ffmpeg to combine segments into ${BOLD}$target_video_path${NC} ..."
        (
            cd "$temp_dir_path" || {
                print_warn "Cannot change directory to temp path $temp_dir_path for ffmpeg." >&2
                exit 1
            }
            local ffmpeg_actual_output
            if ! ffmpeg_actual_output=$("$_FFMPEG" $ffmpeg_ext_picky_opt -f concat -safe 0 -i "$fname_in_temp" -c copy $ffmpeg_error_opt -y "$target_video_path" 2>&1); then
                print_warn "ffmpeg concatenation failed for episode $num." >&2
                if [[ -n "$ffmpeg_actual_output" && ( -n "$_DEBUG_MODE" || "$ffmpeg_error_opt" != "-v error" ) ]]; then
                     print_info "ffmpeg output:" >&2
                     echo "$ffmpeg_actual_output" | sed 's/^/    /' >&2
                fi
                exit 1
            fi
            exit 0
        )
        local subshell_ffmpeg_status=$?
        if [[ $subshell_ffmpeg_status -ne 0 ]]; then
            retval=1
            rm -f "$target_video_path"
        fi
    fi
    if [[ $retval -ne 0 ]]; then
        set_title "✘ Ep $num Failed - $_ANIME_NAME"
        print_warn "Episode ${BOLD}$num${NC} processing failed. Review logs above."
        if [[ -n "${_DEBUG_MODE:-}" && -d "$temp_dir_path" ]]; then
            print_warn "Debug mode: Leaving temporary directory for failed ep $num: ${BOLD}$temp_dir_path${NC}"
        elif [[ -d "$temp_dir_path" ]]; then
            print_info "  Cleaning up temporary directory: ${BOLD}$temp_dir_path${NC}"
            rm -rf "$temp_dir_path"
        fi
        rm -f "$target_video_path"
        return 1
    else
        set_title "✅ Ep $num Done - $_ANIME_NAME"
        print_info "${GREEN}✓ Successfully downloaded and assembled Episode ${BOLD}$num${NC} to ${BOLD}$target_video_path${NC}"
        if [[ -n "${_DEBUG_MODE:-}" && -d "$temp_dir_path" ]]; then
            print_warn "Debug mode: Leaving temporary directory for successful ep $num: ${BOLD}$temp_dir_path${NC}"
        elif [[ -d "$temp_dir_path" ]]; then
            print_info "  Cleaning up temporary directory: ${BOLD}$temp_dir_path${NC}"
            rm -rf "$temp_dir_path"
        fi
        return 0
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
    # $2: anime list file (optional, defaults to global var)
    local search_name_arg="$1"
    local list_file="${2:-$_ANIME_LIST_FILE}"
    awk -F'] ' -v search_name="$search_name_arg" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        BEGIN { IGNORECASE=1 }
        {
            title_from_file = trim($2)
            name_to_search = trim(search_name)
            if (title_from_file == name_to_search) {
                slug_part = $1
                sub(/^\[/, "", slug_part)
                print slug_part
            }
        }
    ' "$list_file" | tail -n 1
}

main() {
    echo
    echo -e "${BOLD}${CYAN}======= AnimePahe Downloader Script =======${NC}"
    set_args "$@"
    set_var
    set_cookie
    echo
    echo -e "${BOLD}${CYAN}======= Selecting Anime =======${NC}"
    local selected_line
    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        local search_results
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
    elif [[ -n "${_ANIME_SLUG:-}" ]]; then
        print_info "Using provided slug: ${BOLD}$_ANIME_SLUG${NC}"
        if [[ ! -f "$__ANIME_LIST_FILE" ]]; then download_anime_list; fi
        _ANIME_NAME=$(grep "^\[${_ANIME_SLUG}\]" "$__ANIME_LIST_FILE" | tail -n 1 | remove_slug | sed 's/[[:space:]]*$//')
        if [[ -z "$_ANIME_NAME" ]]; then
            print_warn "Could not find anime name for slug ${_ANIME_SLUG} in list. Using slug as name."
            _ANIME_NAME="$_ANIME_SLUG"
        fi
    else
        download_anime_list
        local selected_line
        selected_line=$("$_FZF" -1 --exit-0 --delimiter='] ' --with-nth=2.. < "$__ANIME_LIST_FILE")
        if [[ -z "$selected_line" ]]; then
            print_error "No anime selected from the list."
        fi
        _ANIME_SLUG=$(echo "$selected_line" | remove_brackets)
        _ANIME_NAME=$(echo "$selected_line" | remove_slug | sed -E 's/[[:space:]]+$//')
    fi
    [[ -z "$_ANIME_SLUG" ]] && print_error "Could not determine Anime Slug for '${_ANIME_NAME:-unknown anime}'."
    local original_anime_name="${_ANIME_NAME:-Unselected Anime}"
    _ANIME_NAME=$(sanitize_filename "${_ANIME_NAME:-}")
    [[ -z "$_ANIME_NAME" ]] && print_error "Anime name became empty after sanitization! Original was: '${original_anime_name}'"
    print_info "${GREEN}✓ Selected Anime:${NC} ${BOLD}${_ANIME_NAME}${NC} (Slug: ${_ANIME_SLUG})"
    set_title "$_ANIME_NAME - Preparing"
    echo
    echo -e "${BOLD}${CYAN}======= Preparing Download =======${NC}"
    mkdir -p "$_VIDEO_DIR_PATH/$_ANIME_NAME" || print_error "Cannot create target directory: $_VIDEO_DIR_PATH/$_ANIME_NAME"
    download_source "$_ANIME_SLUG" "$_ANIME_NAME" || print_error "Failed to download episode source information for $_ANIME_NAME."
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        _ANIME_EPISODE=$(select_episodes_to_download)
        [[ -z "${_ANIME_EPISODE}" ]] && print_error "No episodes selected for download."
    fi
    print_info "Episode selection for ${_ANIME_NAME}: ${BOLD}${_ANIME_EPISODE}${NC}"
    download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
