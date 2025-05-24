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
_SEGMENT_TIMEOUT="360"

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)"
    trap - EXIT # Unset the EXIT trap specifically for help
    exit 1
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
        print_warn "Failed to get URL: $1"
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
    d=$(get "$_HOST/api?m=search&q=${query}")
    n=$("$_JQ" -r '.total' <<< "$d")
    if [[ "$n" == "null" || "$n" -eq "0" ]]; then
        echo ""
    else
        formatted_results=$("$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d")
        echo -e "$formatted_results"
    fi
}

get_episode_list() {
    # $1: anime id
    # $2: page number
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"
}

download_source() {
  # $1: anime slug
  # $2: anime name (for source file path)
  local anime_slug="$1"
  local anime_name="$2" # Use the global _ANIME_NAME
  local source_path="$_VIDEO_DIR_PATH/$anime_name/$_SOURCE_FILE"

  print_info "${YELLOW}⟳ Downloading episode list for ${BOLD}$anime_name${NC}...${NC}"
  mkdir -p "$_VIDEO_DIR_PATH/$anime_name" # Ensure directory exists

  local d p n i current_page last_page json_data=()
  current_page=1

  while true; do
    print_info "  Fetching page ${BOLD}$current_page${NC}..."
    d=$(get_episode_list "$anime_slug" "$current_page")
    if [[ $? -ne 0 || -z "$d" || "$d" == "null" ]]; then
      # Handle case where first page fails vs subsequent pages
      if [[ $current_page -eq 1 ]]; then
        print_error "Failed to get first page of episode list."
      else
        print_warn "Failed to get page $current_page, proceeding with downloaded data."
        break # Exit loop, use what we have
      fi
    fi

    # Check if data is valid JSON and has expected structure
    if ! echo "$d" | "$_JQ" -e '.data' >/dev/null; then
      if [[ $current_page -eq 1 ]]; then
        print_error "Invalid data received on first page of episode list."
      else
        print_warn "Invalid data received on page $current_page, proceeding with downloaded data."
        break
      fi
    fi

    # Add current page data to our array
    json_data+=("$(echo "$d" | "$_JQ" -c '.data')") # Store as compact JSON strings

    # Get last page number only once
    [[ -z ${last_page:-} ]] && last_page=$("$_JQ" -r '.last_page // 1' <<<"$d")

    if [[ $current_page -ge $last_page ]]; then
      break # Exit loop if we've reached the last page
    fi
    current_page=$((current_page + 1))
    sleep 0.5 # Small delay between page requests
  done

  # Combine all collected JSON data arrays into a single JSON object
  local combined_json
  # Use jq's slurp (-s) and map/add to merge the arrays inside {data: ...}
  combined_json=$(printf '%s\n' "${json_data[@]}" | "$_JQ" -s 'map(.[]) | {data: .}')

  # Save the combined data
  echo "$combined_json" >"$source_path"

  if [[ $? -eq 0 && -s "$source_path" ]]; then
    local ep_count
    ep_count=$(echo "$combined_json" | "$_JQ" -r '.data | length')
    print_info "${GREEN}✓ Successfully downloaded source info for ${BOLD}$ep_count${NC}${GREEN} episodes to ${BOLD}$source_path${NC}"
  else
    rm -f "$source_path"
    print_error "Failed to save episode source file."
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
  local s l

  print_info "    Fetching stream page: ${BOLD}${stream_link}${NC}"
  s="$("$_CURL" --compressed -sS -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" "$stream_link")"
  if [[ $? -ne 0 ]]; then
    print_warn "Failed to get stream page content from $stream_link"
    return 1
  fi

  print_info "    Extracting packed Javascript..."
  s="$(echo "$s" |
    grep "<script>eval(" |
    head -n 1 |
    awk -F 'script>' '{print $2}' |
    sed -E 's/<\/script>//' |
    sed -E 's/document/process/g' |
    sed -E 's/querySelector/exit/g' |
    sed -E 's/eval\(/console.log\(/g')"
  if [[ -z "$s" ]]; then
    print_warn "Could not extract packed JS block from stream page."
    return 1
  fi

  print_info "    Executing JS with node.js to find m3u8 URL..."
  l="$("$_NODE" -e "$s" 2>/dev/null |
    grep 'source=' |
    head -n 1 |
    sed -E "s/.m3u8['\"].*/.m3u8/" |
    sed -E "s/.*['\"](https:.*)/\1/")" # More robust extraction

  if [[ -z "$l" || "$l" != *.m3u8 ]]; then
    print_warn "Failed to extract m3u8 link using node.js."
    return 1
  fi

  print_info "    ${GREEN}✓ Found playlist URL.${NC}"
  echo "$l"
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
  # ARG 3: MaxRetries ($3, optional default 3)
  # ARG 4: InitialDelay ($4, optional default 2)
  # Uses ENVIRONMENT: _CURL, _REFERER_URL, _COOKIE

  local url="$1"
  local outfile="$2"
  local max_retries=${3:-3}
  local initial_delay=${4:-2}
  local attempt=0 delay=$initial_delay s=0

  # --- REMOVED THE INTERNAL PATH CONSTRUCTION BLOCK ---

  # Only create a filename if outfile is empty (which it shouldn't be btw)
  if [[ -z "$outfile" ]]; then
    # Use parameter expansion instead of sed for better performance
    local filename=${url##*/} # Remove everything before last /
    filename=${filename%%\?*} # Remove query string if present
    filename=${filename%%\#*} # Remove fragment if present

    # Use direct parameter expansion instead of conditional check + assignment
    outfile="${opath:-.}/${filename}.encrypted"
    [[ "$opath" == "." ]] && print_warn "Output path (opath) is not set. Using current directory."
  fi

  # Use the BASENAME of the PASSED outfile path ($2) for messages
  local display_filename=$(basename "$outfile")

  # Debug print - Shows the arguments as received
  # print_warn "DEBUG inside download_file: url='$url' outfile='$outfile' retries='$max_retries' delay='$initial_delay'"

  while [[ $attempt -lt $max_retries ]]; do
    attempt=$((attempt + 1))

    local curl_stderr
    curl_stderr=$({
      # Use the passed 'outfile' variable ($2)
      "$_CURL" --fail -sS -H "Referer: $_REFERER_URL" -H "cookie: $_COOKIE" -C - "$url" -L -g \
        --connect-timeout 10 \
        --retry 2 --retry-delay 1 \
        --compressed \
        -o "$outfile"
      s=$?
    } 2>&1 >/dev/null)

    if [[ "$s" -eq 0 ]]; then
      if [[ -s "$outfile" ]]; then
        return 0 # Success :)
      else
        print_warn "      Download succeeded (curl code 0) but output file is empty/missing: ${BOLD}${display_filename}${NC}"
        s=99
      fi
    fi

    if [[ $attempt -lt $max_retries ]]; then
      print_warn "      Download attempt $attempt/$max_retries failed (curl code: $s) for ${display_filename}. Retrying in $delay seconds..."
    fi
    rm -f "$outfile"
    sleep "$delay"
    delay=$((delay * 2))
  done

  print_warn "Download failed after $max_retries attempts for ${display_filename} ($url)"
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
  # Uses environment variables: plist, opath, threads, _CURL, _REFERER_URL, _COOKIE
  # Needs exported functions: download_file, print_info, print_warn, print_error
  # Also uses global _SEGMENT_TIMEOUT if set by -T flag

  local segment_urls=()
  local retval=0

  mapfile -t segment_urls < <(grep "^https" "$plist")
  local total_segments=${#segment_urls[@]}
  if [[ $total_segments -eq 0 ]]; then
    print_warn "No segment URLs found in playlist: $plist"
    return 1
  fi

  print_info "  Downloading ${BOLD}$total_segments${NC} segments using ${BOLD}$threads${NC} thread(s) via GNU Parallel."

  local parallel_opts=()
  parallel_opts+=("--jobs" "$threads")
  parallel_opts+=("--bar")
  parallel_opts+=("--quote")

  if [[ -n "${_SEGMENT_TIMEOUT:-}" ]]; then
    print_info "    (Individual download job timeout: ${_SEGMENT_TIMEOUT}s)"
    parallel_opts+=("--timeout" "${_SEGMENT_TIMEOUT}s")
  fi

  # Export function and variables needed DIRECTLY by the parallel JOB
  export -f download_file print_info print_warn print_error
  export _CURL _REFERER_URL _COOKIE opath # _PV is not needed inside download_file

  # --- Run GNU Parallel ---
  # Explicitly pass necessary env vars/funcs
  # SIMPLIFIED COMMAND STRING: Just call download_file with the URL {}
  printf '%s\n' "${segment_urls[@]}" |
    "$_PARALLEL" "${parallel_opts[@]}" \
      --env download_file --env print_info --env print_warn --env print_error \
      --env _CURL --env _REFERER_URL --env _COOKIE --env opath \
      -- download_file {}

  local parallel_status=$?

  # --- Check Exit Status (Same as before) ---
  if [[ $parallel_status -ne 0 ]]; then
    print_warn "GNU Parallel reported errors or timeouts during segment download (exit status: $parallel_status)."
    retval=1
  fi

  # --- Final Check: Segment Count (Same as before) ---
  local final_download_count
  final_download_count=$(find "$opath" -maxdepth 1 -name '*.encrypted' -print 2>/dev/null | wc -l)
  if [[ "$final_download_count" -ne "$total_segments" ]]; then
    [[ $retval -eq 0 ]] && print_warn "Segment count mismatch after parallel finished. Expected $total_segments, found $final_download_count."
    retval=1
  elif [[ $retval -eq 0 ]]; then
    print_info "  ${GREEN}✓ Segment download phase complete (GNU Parallel).${NC}"
  fi

  # Final reporting on failure (Same as before)
  if [[ $retval -ne 0 ]]; then
    local downloaded_count
    downloaded_count=$(find "$opath" -maxdepth 1 -name '*.encrypted' -print 2>/dev/null | wc -l)
    print_warn "  Failed State -> Expected: ${total_segments}, Actually Downloaded: ${downloaded_count}"
  fi

  return $retval
}

generate_filelist() {
  # $1: playlist file (source for segment names)
  # $2: output file list path
  local playlist_file="$1" outfile="$2" opath
  opath=$(dirname "$outfile") # Get directory path

  print_info "  Generating file list for ffmpeg..."
  # Modify segment URLs from playlist to point to *decrypted* local files
  grep "^https" "$playlist_file" |
    sed -E "s/^https.*\///" |
    # Improved regex to handle various segment extensions and potential query strings
    sed -E 's/(\.(ts|jpg|mp4|m4s|aac))(\?.*|#.*)?$/\1/' |
    sed -E "s/^/file '/" |
    sed -E "s/$/'/" \
      >"$outfile"

  # Check if file list was created and is not empty
  if [[ ! -s "$outfile" ]]; then
    print_warn "Failed to generate or generated empty file list for this episode: $outfile"
    return 1
  fi

  # Verify that the files listed actually exist (decrypted)
  local missing_files=0
  local missing_list=() # Optional: list missing files
  while IFS= read -r line; do
    local segment_file="${line#file \'}"
    segment_file="${segment_file%\'}"
    # Check if the expected decrypted file exists
    if [[ ! -f "${opath}/${segment_file}" ]]; then
      print_warn "    File listed in $(basename "$outfile") not found: ${segment_file}"
      missing_files=$((missing_files + 1))
      # missing_list+=("$segment_file") # Uncomment to collect list
    fi
  done <"$outfile"

  # Check the total count of missing files
  if [[ $missing_files -gt 0 ]]; then
    print_warn "$missing_files segment file(s) listed in $(basename "$outfile") are missing on disk for this episode!"
    return 1
  fi

  print_info "  ${GREEN}✓ File list generated: ${BOLD}$outfile${NC}"
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
    local tmp_pattern_base="ep*_*.${$}.XXXXXX"
    find "${_VIDEO_DIR_PATH:-$HOME/Videos}" -maxdepth 3 -path "*/*/*" -type d -name "$tmp_pattern_base" -exec rm -rf {} + 2>/dev/null
    find /tmp -maxdepth 1 -type d -name "$tmp_pattern_base" -exec rm -rf {} + 2>/dev/null
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
    if [[ -n "${_NOTIFICATION_CMD:-}" ]]; then
        "$_NOTIFICATION_CMD" -a "animepahe downloader" -u "${_NOTIFICATION_URG}" "$1" "$2"
    fi
}

sanitize_filename() {
    echo "$1" | sed -E \
        -e 's/[^[:alnum:] ,+\-\)\(._]/_/g' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//'
}

download_episode() {
  local num="$1"                        # Episode number string
  local v                               # Target video file path
  local l                               # Episode page link (kwik)
  local pl                              # m3u8 playlist link
  local erropt=''                       # ffmpeg error level option
  local opath plist cpath fname threads # Temporary directory variables
  local retval=0                        # Track success/failure

  # Define target path early for checking existence
  v="$_VIDEO_DIR_PATH/$_ANIME_NAME/${num}.mp4"

  # Check if file already exists
  if [[ -f "$v" ]]; then
    print_info "${GREEN}✓ Episode ${BOLD}$num ($v)${NC}${GREEN} already exists. Skipping.${NC}"
    return 0 # Success (already done)
  fi

  # --- Get Links ---
  print_info "Processing Episode ${BOLD}$num${NC}:"
  l=$(get_episode_link "$num") || return 1
  print_info "  Found stream page link: ${BOLD}$l${NC}"

  pl=$(get_playlist_link "$l") || return 1
  print_info "  Found playlist URL: ${BOLD}$pl${NC}"

  # Handle -l option (list link only)
  if [[ -n "${_LIST_LINK_ONLY:-}" ]]; then
    echo "$pl" # Print the link
    return 0   # Success for this mode
  fi

  # --- Prepare for Download ---
  set_title "⏳ $_ANIME_NAME - Episode $num" # Set terminal title
  print_info "Starting download process for Episode ${BOLD}$num${NC}..."

  [[ -z "${_DEBUG_MODE:-}" ]] && erropt="-v error"

  fname="file.list"
  cpath="$(pwd)" # Save current directory (might not be needed if using absolute paths)

  # Create unique temporary directory using mktemp
  opath=$("$_MKTEMP" -d "$_VIDEO_DIR_PATH/$_ANIME_NAME/ep${num}_${$}_XXXXXX")
  if [[ ! -d "$opath" ]]; then
    print_warn "Failed to create temporary directory for episode $num: Check permissions and path."
    return 1
  fi
  print_info "  Created temporary directory: ${BOLD}$opath${NC}"
  plist="${opath}/playlist.m3u8"

  # --- Download & Process Segments ---
  print_info "  Downloading master playlist..."
  # Pass URL, Outfile, Retries (3), Delay (2) EXPLICITLY
  download_file "$pl" "$plist" 3 2 || retval=1

  # Assign the value for 'threads' which download_segments will use from environment
  threads="$_PARALLEL_JOBS"

  if [[ $retval -eq 0 ]]; then
    print_info "  ${CYAN}--- Segment Download Phase ---${NC}"

    # Export environment needed by download_segments AND its jobs
    export -f download_segments download_file print_info print_warn print_error
    # Export necessary variables BY NAME. _PV is no longer needed here.
    export _CURL _REFERER_URL _COOKIE opath plist threads

    # Call download_segments directly
    download_segments || retval=1
  fi

  # The rest of the function proceeds based on the 'retval' flag
  if [[ $retval -eq 0 ]]; then
    set_title "🔑  $_ANIME_NAME - Episode $num - Decrypting"
    print_info "  ${CYAN}--- Segment Decryption Phase ---${NC}"
    # Pass threads explicitly as it's used for parallel decryption jobs
    decrypt_segments "$plist" "$opath" "$threads" || retval=1
  fi

  if [[ $retval -eq 0 ]]; then
    print_info "  ${CYAN}--- File List Generation ---${NC}"
    generate_filelist "$plist" "${opath}/$fname" || retval=1
  fi

  # --- Concatenate ---
  if [[ $retval -eq 0 ]]; then
    set_title "🔗  $_ANIME_NAME - Episode $num - Concatenating"
    print_info "  ${CYAN}--- Concatenation Phase ---${NC}"
    ( # Start Subshell
      cd "$opath" || {
        print_warn "Cannot change directory to temp path $opath" >&2
        exit 1
      }
      print_info "  Running ffmpeg to combine segments into ${BOLD}$v${NC} ..." >&2

      local ffmpeg_output
      if ! ffmpeg_output=$("$_FFMPEG" -f concat -safe 0 -i "$fname" -c copy $erropt -y "$v" 2>&1); then
        print_warn "ffmpeg concatenation failed for episode $num." >&2
        print_info "ffmpeg output:" >&2
        echo "$ffmpeg_output" | sed 's/^/    /' >&2
        exit 1 # Exit subshell with failure
      fi
      exit 0 # Success
    )        # End Subshell
    local subshell_status=$?
    if [[ $subshell_status -ne 0 ]]; then
      retval=1
      # Warning already printed in subshell
      rm -f "$v"
    fi
  fi

  # --- Cleanup and Return ---
  if [[ $retval -ne 0 ]]; then
    # Failure message was printed inside the failing function or timeout logic
    print_warn "Episode ${BOLD}$num${NC} processing failed or timed out. Cleaning up."
    if [[ -d "$opath" ]]; then # Check if temp dir was created
      if [[ -z "${_DEBUG_MODE:-}" ]]; then
        print_info "  Cleaning up temporary directory: ${BOLD}$opath${NC}"
        rm -rf "$opath"
      else
        print_warn "Debug mode: Leaving temporary directory: ${BOLD}$opath${NC}"
      fi
    fi
    rm -f "$v" # Ensure target file is removed on failure
    return 1   # Signal failure for THIS episode
  else
    set_title "✅  $_ANIME_NAME - Episode $num - Finished"
    print_info "${GREEN}✓ Successfully downloaded and assembled Episode ${BOLD}$num${NC} to ${BOLD}$v${NC}"
    if [[ -d "$opath" ]]; then # Check if temp dir exists
      if [[ -z "${_DEBUG_MODE:-}" ]]; then
        print_info "  Cleaning up temporary directory: ${BOLD}$opath${NC}"
        rm -rf "$opath"
      else
        print_warn "Debug mode: Leaving temporary directory: ${BOLD}$opath${NC}"
      fi
    fi
    return 0 # Signal success
  fi
}


select_episodes_to_download() {
    local source_path="$_VIDEO_DIR_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    local ep_count
    ep_count=$("$_JQ" -r '.data | length' "$source_path")
    if [[ "$ep_count" -eq 0 ]]; then
        print_error "No episodes found in source file: $source_path"
    fi
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
        search_results=$(search_anime_by_name "$_INPUT_ANIME_NAME")
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
        if [[ ! -f "$_ANIME_LIST_FILE" ]]; then download_anime_list; fi
        _ANIME_NAME=$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" | sed -E 's/^\[[^]]+\] //;s/   *$//')
        if [[ -z "$_ANIME_NAME" ]]; then
            print_warn "Could not find anime name for slug ${_ANIME_SLUG} in list. Using slug as name."
            _ANIME_NAME="$_ANIME_SLUG"
        fi
    else
        download_anime_list
        local selected_line
        selected_line=$("$_FZF" -1 --exit-0 --delimiter='] ' --with-nth=2.. < "$_ANIME_LIST_FILE")
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
