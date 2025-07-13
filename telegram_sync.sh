#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
if [[ "${TRACE-0}" == 1 ]]; then set -o xtrace; fi
# Fetch files from telegram groups
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
trap 'pkill -P $$; exit' SIGINT SIGTERM

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

# shellcheck disable=SC2120
print_with_indent() {
    # Pipe stdin to stdout with each line indented by 4 spaces
    _assert_no_params "$@"
    sed 's/^/    /'
}

get_latest_message_id() {
    local -r chat="$1"
    local -r tmpout="$2"
    shift 2
    _assert_no_params "$@"

    echo "==> Getting latest message ID"
    {
        tdl chat export -c "$chat" -o "$tmpout" -T last -i 1 --all >/var/log/tdl_progress.log
    } 2>&1 | print_with_indent
}

export_message_list() {
    local -r chat="$1"
    local -r output="$2"
    local -r start_id="$3"
    local -r end_id="$4"
    shift 4
    _assert_no_params "$@"

    echo "==> Exporting messages ($start_id - $end_id)"
    {
        tdl chat export -c "$chat" -o "$output" -T id -i "${start_id},${end_id}" --all --with-content --pool 0 --delay 2s >/var/log/tdl_progress.log
    } 2>&1 | print_with_indent
}

tdl_download_wrapper() {
    local -r output_dir="$1"
    local -r cmd="$2"
    local -r cmd_arg="$3"
    local -r external_id="$4"
    shift 4
    _assert_no_params "$@"

    local template
    if [[ -n "$external_id" ]]; then
        template="{{ trunc -5 ( list \"00000\" \"${external_id}\" | join \"\" ) }}_{{ trunc 96 ( regexReplaceAllLiteral \"[<>:\\\"/\\\\|?*\\x00-\\x1F]\" .FileCaption \"\" )  }}{{ if .FileCaption }}_{{ end }}{{ trunc 96 ( regexReplaceAllLiteral \"[<>:\\\"/\\\\|?*\\x00-\\x1F]\" .FileName \"\" ) }}_{{ .DialogID }}_{{ .MessageID }}.mp4"
    else
        template="{{ trunc -5 ( list \"00000\" .MessageID | join \"\" ) }}_{{ trunc 96 (regexReplaceAllLiteral \"[<>:\\\"/\\\\|?*\\x00-\\x1F]\" .FileCaption \"\" ) }}{{ if .FileCaption }}_{{ end }}{{ trunc 96 ( regexReplaceAllLiteral \"[<>:\\\"/\\\\|?*\\x00-\\x1F]\" .FileName \"\" ) }}_{{ .DialogID }}.mp4"
    fi
    readonly template
    {
        tdl dl --template "$template" --continue --rewrite-ext --dir "$output_dir" "$cmd" "$cmd_arg" --skip-same --pool 0 --delay 1s --limit 4 --threads 4 >/var/log/tdl_progress.log
    } 2>&1
}

download_from_message_list() {
    local -r input_message_list="$1"
    local -r output_dir="$2"
    shift 2
    _assert_no_params "$@"

    local len
    len="$(jq -r '.messages | length' "$input_message_list")"
    readonly len
    echo "==> Downloading $len media(s)"

    # Download embed media
    {
        if tdl_download_wrapper "$output_dir" --file "$input_message_list" ""; then
            echo "==> Download completed"
        else
            local -r exit_code="$?"
            echo "==> Download failed with exit code $exit_code"
            return "$exit_code"
        fi
    } | print_with_indent || return "$?"

    # Download URLs
    jq -r ".messages[] | select(.file==\"\") | .id + \":\" .text" "$input_message_list" | while read -r line; do
        local external_id="${line%%:*}"
        line="${line#*:}"

        if [[ "$line" == https://telegra.ph* ]]; then
            {
                echo "==> Attempting to download $line using telegraph.py"
                {
                    if python /usr/local/bin/telegraph.py "$output_dir" "$external_id" "$line" 2>&1; then
                        echo "==> Download completed"
                    else
                        local -r exit_code="$?"
                        echo "==> Download failed with exit code $exit_code"
                        return "$exit_code"
                    fi
                } | print_with_indent || return "$?"
            } | print_with_indent || return "$?"
        elif [[ "$line" == https://t.me* ]]; then
            {
                echo "==> Attempting to download $line using tdl url argument"
                {
                    if tdl_download_wrapper "$output_dir" --url "$line" "$external_id"; then
                        echo "==> Download completed"
                    else
                        local -r exit_code="$?"
                        echo "==> Download failed with exit code $exit_code"
                        return "$exit_code"
                    fi
                } | print_with_indent || return "$?"
            } | print_with_indent || return "$?"
        else
            echo "==> Warning: ignoring unknown text $line with external id $external_id" | print_with_indent
        fi
    done
}

sync_chat() {
    local -r chat="$1"
    local -r out_dir="$2"
    shift 2
    _assert_no_params "$@"

    local -r message_list="$tmp_dir/message_list.json"
    echo "==> Syncing chat $chat to $out_dir"
    while true; do
        {
            if get_latest_message_id "$chat" "$message_list"; then
                echo "==> Get latest message ID completed" | print_with_indent
            else
                local -r exit_code="$?"
                echo "==> Get latest message ID failed with exit code $exit_code" | print_with_indent
                return "$exit_code"
            fi
        } | print_with_indent || return "$?"
        local latest_id
        latest_id="$(jq -r ".messages | map(.id) | max" "$message_list")"

        case $latest_id in
        '' | *[!0-9]*)
            echo "==> Failed to get latest id ($latest_id) for chat $chat" | print_with_indent
            return 1
            ;;
        esac

        local old_id=0
        if [ -f "$STAMPS_DIR/$chat" ]; then
            old_id="$(cat "$STAMPS_DIR/$chat")"
        fi

        if [ "$old_id" -ge "$latest_id" ]; then
            echo "==> No new messages in chat $chat ($old_id >= $latest_id)" | print_with_indent
            return 0
        fi

        echo "==> Latest ID: $latest_id" | print_with_indent
        local start_id="$((old_id + 1))"
        local end_id="$((start_id + BATCH_SIZE))"
        if [ "$end_id" -gt "$latest_id" ]; then
            end_id="$latest_id"
        fi

        {
            export_message_list "$chat" "$message_list" "$start_id" "$end_id" || return "$?"
        } | print_with_indent || return "$?"
        {
            download_from_message_list "$message_list" "$out_dir" || return "$?"
        } | print_with_indent || return "$?"

        echo "$end_id" >"$STAMPS_DIR/$chat"
    done
}

tmp_dir="$(mktemp -d)"
readonly tmp_dir
chmod go-rwx "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ -f "${COOKIE_FILE-/etc/telegram.conf}" ]]; then
    # shellcheck disable=SC1090
    source "${COOKIE_FILE-/etc/telegram.conf}"
fi

if [[ -z "${STAMPS_DIR+x}" ]]; then
    readonly STAMPS_DIR="$HOME/.tg_stamps"
fi
if [[ -z "${BATCH_SIZE+x}" ]]; then
    readonly BATCH_SIZE=32
fi

while true; do
    for chat in "${CHATS[@]}"; do
        if sync_chat "${chat%%:*}" "${chat##*:}"; then
            echo "==> Chat ${chat%%:*} synced successfully"
            continue
        else
            exit_code="$?"
            echo "==> Chat ${chat%%:*} failed to sync with exit code $exit_code"
            continue
        fi
    done
    echo "==> Sleeping from $(date)"
    sleep 5m &
    wait $!
done
