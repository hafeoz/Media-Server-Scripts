#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
if [[ "${TRACE-0}" == 1 ]]; then set -o xtrace; fi
# Fetch video from Bilibili favlists
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
        local linen="${BASH_LINENO[$((bt - 1))]}"
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

get_fav_list() {
    local -r fav_id="$1"
    shift
    _assert_no_params "$@"

    echo "==> Getting BVIDs inside favlist"
    curl --get -sS 'https://api.bilibili.com/x/v3/fav/resource/ids' --data-urlencode "media_id=$fav_id" --data-urlencode 'platform=web' -b "$COOKIE" | jq -r '.data[] | ((.id|tostring) + ":" + (.type|tostring) + ";" + (.bvid|tostring))' | tac
}
download_bvid() {
    local -r bvid="$1"
    local -r out_dir="$2"
    local -r base_dir="$3"
    shift 3
    _assert_no_params "$@"

    if [[ "$(find "$base_dir" -type f -iname "*\ \[$bvid\]\.*" -print0 | wc -c)" -ne 0 ]]; then
        while IFS= read -r -d $'\0' video_file; do
            echo "==> Updating danmaku for $video_file"
            yt-dlpp update-danmaku "$video_file" || return "$?"
        done < <(find "$base_dir" -type f -iname "*\ \[$bvid\]\.*" -print0)
    else
        echo "==> Downloading $bvid"
        yt-dlpp download "$bvid" "$out_dir" || return "$?"
    fi
}
remove_from_sav_list() {
    local -r fav_id="$1"
    local -r resource="$2"
    local -r result="$(curl -sS 'https://api.bilibili.com/x/v3/fav/resource/batch-del' \
        --data-urlencode "resources=$resource" \
        --data-urlencode "media_id=$fav_id" \
        --data-urlencode 'platform=web' \
        --data-urlencode "csrf=$COOKIE_BILI_JCT" \
        -b "$COOKIE" | jq -r ".message")"
    echo "=> Removed $resource from favlist (message $result)"
}
sync_fav_list() {
    local -r fav_id="$1"
    local -r out_dir="$2"
    echo "----------------"
    echo "Syncing fav list $fav_id to $out_dir"
    get_fav_list "$fav_id" | while read -r line; do
        local bvid="${line##*;}"
        local resource="${line%%;*}"
        if download_bvid "$bvid" "$out_dir"; then
            if remove_from_sav_list "$fav_id" "$resource"; then
                continue
            else
                local errcode="$?"
                >&2 echo "Failed to remove $bvid from favlist, error code $errcode"
                continue
            fi
        else
            local errcode="$?"
            >&2 echo "Failed to download $bvid, error code $errcode"
            continue
        fi
    done
}

if [[ -f "${COOKIE_FILE-/etc/bilibili.conf}" ]]; then
    # shellcheck disable=SC1090
    source "${COOKIE_FILE-/etc/bilibili.conf}"
fi

while true; do
    for favlist in "${FAVLISTS[@]}"; do
        sync_fav_list "${favlist%%:*}" "${favlist##*:}"
    done

    echo "----------------"
    echo "==> Sleeping from $(date)"
    sleep 5m &
    wait $!
done
