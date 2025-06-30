#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
if [[ "${TRACE-0}" == 1 ]]; then set -o xtrace; fi
# A yt-dlpp wrapper for OliveTin
#
# This software is licensed under BSD Zero Clause OR CC0 v1.0 Universal OR
# WTFPL Version 2. You may choose any of them at your will.
#
# The software is provided "as is" and the author disclaims all warranties with
# regard to this software including all implied warranties of merchantability
# and fitness. In no event shall the author be liable for any special, direct,
# indirect, or consequential damages or any damages whatsoever resulting from
# loss of use, data or profits, whether in an action of contract, negligence or
# other tortious action, arising out of or in connection with the use or
# performance of this software.

_get_stack() {
    # https://gist.github.com/akostadinov/33bb2606afe1b334169dfbf202991d36
    local -r stack_size="${#FUNCNAME[@]}"
    local bt
    for ((bt = 1; bt < stack_size; bt++)); do
        local func="${FUNCNAME[$bt]}"
        [[ $func = "" ]] && func=MAIN
        local -r linen="${BASH_LINENO[$((bt - 1))]}"
        local src="${BASH_SOURCE[$bt]}"
        [[ "$src" = "" ]] && src=non_file_source

        echo "   at: $func() $src (line $linen)"
    done
}
_raise_fatal_error() {
    local -r message="$1"
    echo "SCRIPT BUG: $message" >&2
    _get_stack >&2
    exit 1
}
_assert_no_params() {
    if [[ "$#" -ne 0 ]]; then
        _raise_fatal_error "$# more parameters than expected ($*)"
    fi
}

is_true() {
    # Check if a value is true
    local val="$1"
    shift
    _assert_no_params "$@"

    val="${val,,}"
    [[ "$val" == "true" ]] || [[ "$val" == "yes" ]] || [[ "$val" == "1" ]]
}

extract_bvid() {
    local -r url="$1"
    shift
    _assert_no_params "$@"

    local -r bvid_regex="https?:\/\/(www\.)?bilibili\.com\/(video\/|festival\/\w+\?([^#]*&)?bvid=)([aAbB][vV][^\/?#&]+)"
    if [[ "$url" =~ $bvid_regex ]]; then
        local -r vid="${BASH_REMATCH[4]}"
        echo "$vid"
    fi
}

find_video_with_id() {
    local -r path="$1"
    local -r id="$2"
    shift 2
    _assert_no_params "$@"

    find "$path" -type f -iname "*\ \[$id\]\.*" -print0
}

if [[ -n "${UMASK+x}" ]]; then
    umask "$UMASK"
fi

if [[ "$#" -ne 4 ]]; then
    echo "Usage: $0 [video|audio] [URL] [DOWNLOAD_PATH] [update_if_exists]"
    exit 1
fi

bvid="$(extract_bvid "$2")"
readonly bvid
if [[ -n "$bvid" ]]; then
    # Check if video with such id already exists
    if [[ "$(find_video_with_id "$3" "$bvid" | wc -c)" -ne 0 ]]; then
        if is_true "$4"; then
            echo "> Updating danmaku for existing video..."
            while IFS= read -r -d $'\0' video_file; do
                echo "> Updating danmaku for $video_file"
                yt-dlpp update-danmaku "$video_file"
            done < <(find_video_with_id "$3" "$bvid")
        else
            echo "> Video with id $bvid already exists!"
            while IFS= read -r -d $'\0' video_file; do
                echo "    > $video_file"
            done < <(find_video_with_id "$3" "$bvid")
        fi
        exit 0
    fi
fi

case "$1" in
video)
    yt-dlpp download "$2" "$3"
    ;;
audio)
    yt-dlpp audio "$2" "$3"
    ;;
*)
    echo "Unknown mode: $1"
    exit 1
    ;;
esac
