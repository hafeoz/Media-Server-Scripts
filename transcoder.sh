#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
if [[ "${TRACE-0}" == 1 ]]; then set -o xtrace; fi
# Transcode video to endpoint-friendly formats
# Required environment variables:
# - SRC_DIR, DST_DIR and DST_DIR_SMALL: video in SRC_DIR will will be transcoded to DST_DIR and DST_DIR_SMALL
# - INPLACE_DIR: video in INPLACE_DIR will be transcoded in place
# - TRANSCODE_VAAPI_THREADS: how many threads can use VAAPI at a time
# - TRANSCODE_CPU_THREADS: how many threads can use CPU at a time
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

calculate_required_bitrate() {
    # Calculate bitrate necessary for converted video
    local -r input_file="$1"
    shift
    _assert_no_params "$@"

    local size
    size="$(stat -c %s --dereference -- "$input_file")"
    readonly size
    local duration
    duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$input_file")"
    readonly duration

    local required_bitrate
    required_bitrate="$(echo "($size * 8 / $duration / 1000 * 2.0)/1 + 1500" | bc)"
    required_bitrate="$((required_bitrate > 3000 ? required_bitrate : 3000))"
    echo "${required_bitrate}k"
}

ffmpeg_wrapper() {
    nice --adjustment=19 -- ffmpeg -nostdin -hide_banner -loglevel error -y "$@"
}

ffmpeg_cpu_transcode() {
    local -r input_file="$1"
    local -r bitrate="$2"
    shift 2
    ffmpeg_wrapper -i "$input_file" \
        -movflags +faststart -x264opts opencl -tune fastdecode -reserve_index_space 50k -b:v "$bitrate" -c:v libx264 -svtav1-params 'fast-decode=3:tune=0:enable-qm=1:qm-min=0' -preset slow -map 0:v:0? "$@" 0<&-
}
ffmpeg_cpu_transcode_crf() {
    local -r input_file="$1"
    local -r bitrate="$2"
    shift 2
    ffmpeg_wrapper -i "$input_file" \
        -movflags +faststart -x264opts opencl -tune fastdecode -reserve_index_space 50k -crf 22 -c:v libx264 -svtav1-params 'fast-decode=3:tune=0:enable-qm=1:qm-min=0' -preset slow -map 0:v:0? "$@" 0<&-
}
ffmpeg_cpu_transcode_crf_small() {
    local -r input_file="$1"
    local -r bitrate="$2"
    shift 2
    ffmpeg_wrapper -i "$input_file" \
        -movflags +faststart -x264opts opencl -tune fastdecode -reserve_index_space 50k -crf 28 -c:v libx264 -svtav1-params 'fast-decode=3:tune=0:enable-qm=1:qm-min=0' -preset slow -map 0:v:0? "$@" 0<&-
}
ffmpeg_vaapi_transcode() {
    local -r input_file="$1"
    local -r bitrate="$2"
    shift 2
    ffmpeg_wrapper -init_hw_device vaapi=vadevice:/dev/dri/renderD128 -hwaccel vaapi -hwaccel_device vadevice -filter_hw_device vadevice -i "$input_file" \
        -movflags +faststart -x264opts opencl -tune fastdecode -reserve_index_space 50k -compression_level 29 -b:v "$bitrate" -c:v h264_vaapi -map 0:v:0? "$@" 0<&-
}
ffmpeg_merge() {
    local -r input_file="$1"
    local -r transcoded_file="$2"
    local -r audio_file="$3"
    shift 3
    ffmpeg_wrapper -i "$transcoded_file" -i "$input_file" -i "$audio_file" \
        -movflags +faststart -tune fastdecode -reserve_index_space 50k -c copy -map 0 -map 2:a? "$@" 0<&- # Add -map 1:v to copy original video content too
}

transcode_file() {
    local -r input_file="$1"
    local -r output_file="$2"
    local -r job_id="$3"
    local -r is_small="$4"
    shift 4
    _assert_no_params "$@"

    local input_file_copied
    input_file_copied="$(mktemp --suffix=.mkv)"
    readonly input_file_copied
    local normalized_file
    normalized_file="$(mktemp --suffix=.mkv)"
    readonly normalized_file
    local transcoded_file
    transcoded_file="$(mktemp --suffix=.mkv)"
    readonly transcoded_file
    local output_file_copied
    output_file_copied="$(mktemp --suffix=.mkv)"
    readonly output_file_copied
    trap 'rm -f -- "$input_file_copied" "$normalized_file $transcoded_file" "$output_file_copied"' RETURN

    cp -f -- "$input_file" "$input_file_copied"

    local bitrate
    bitrate="$(calculate_required_bitrate "$input_file_copied")"
    readonly bitrate

    # Normalize audio
    echo "    $(date): normalizing audio for $output_file"
    ffmpeg-normalize "$input_file_copied" -o "$normalized_file" -f --dual-mono --keep-loudness-range-target -c:a flac -vn -sn -mn -cn || (
        echo "    $(date): ffmpeg-normalize $output_file failed; failing back to plain audio"
        cp -f -- "$input_file_copied" "$normalized_file"
    )

    # Find all subtitle streams
    local subtitle_vf=""  # ffmpeg vf for burning subtitle into video
    local subtitle_map=() # map other subtitles transparently
    local subtitle_id=0
    while read -r -u 10 line; do
        if [[ "$line" == *","* ]]; then
            subtitle_map+=("-map" "0:s:${subtitle_id}")
        else
            subtitle_vf="${subtitle_vf}subtitles=${input_file_copied}:stream_index=${subtitle_id},"
        fi
        subtitle_id="$((subtitle_id + 1))"
    done 10< <(ffprobe -hide_banner -loglevel error -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 -- "$input_file_copied")
    readonly subtitle_vf subtitle_map subtitle_id

    # Interpolate video if <60 fps
    local fps
    fps="$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 -- "$input_file_copied")"
    fps="$(echo "$fps" | bc)"
    readonly fps
    local interpolate_opts=""
    if [[ "$fps" -lt 59 ]]; then
        #interpolate_opts=",minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc"
        interpolate_opts=",fps=fps=60"
    fi

    echo "    $(date): transcoding $output_file (bitrate $bitrate)"
    local -r start_time=$SECONDS

    if ! "ffmpeg_cpu_transcode_crf$is_small" "$input_file_copied" "$bitrate" -vf "scale='max(iw, 960)':-1:flags=lanczos,pad=ceil(iw/2)*2:ceil(ih/2)*2$interpolate_opts,$subtitle_vf" "${subtitle_map[@]}" "$transcoded_file" >/dev/null 2>&1; then
        # Subtitle burn-in failed; attempt without subtitle burn-in
        if ! "ffmpeg_cpu_transcode_crf$is_small" "$input_file_copied" "$bitrate" -vf "scale='max(iw, 960)':-1:flags=lanczos,pad=ceil(iw/2)*2:ceil(ih/2)*2$interpolate_opts" "$transcoded_file"2 >&1 | sed 's/^/        /'; then
            echo "    $(date): Failed to merge $output_file"
            rm -f -- "$input_file_copied" "$output_file_copied" "$transcoded_file" "$normalized_file"
        fi
    fi
    if ! ffmpeg_merge "$input_file_copied" "$transcoded_file" "$normalized_file" "$output_file_copied"2 >&1 | sed 's/^/        /'; then
        echo "    $(date): Failed to merge $output_file"
        rm -f -- "$input_file_copied" "$output_file_copied" "$transcoded_file" "$normalized_file"
        return
    fi

    echo "    $(date): $output_file transcoded successfully using CPU ($((SECONDS - start_time))s used | job id $job_id)"
    mv -- "$output_file_copied" "$output_file"
    rm -f -- "$input_file_copied" "$transcoded_file" "$normalized_file"

    return
}

probe_file() {
    # Probe file to check if it's corrupted
    local file="$1"
    shift
    _assert_no_params "$@"

    # https://stackoverflow.com/a/58825153
    if ! ffprobe "$file" >/dev/null 2>&1 0<&-; then
        echo "    $(date): $file cannot be read by ffmpeg. It might be corrupted. Removing."
        rm -- "$file"
    fi
}

scan_folder() {
    echo "$(date): Scanning input folder"
    local total_numbers="$((TRANSCODE_CPU_THREADS))"
    local job_count="0"
    while IFS= read -r -u 11 -d $'\0' src_file; do
        if [[ ! -f "$src_file" ]]; then continue; fi

        local dst_file="${src_file/"$SRC_DIR"/"$DST_DIR"}"
        dst_file="${dst_file%.*}.mkv"
        if [[ -f "$dst_file" ]]; then
            if [[ "$dst_file" -ot "$src_file" ]]; then
                echo "$(date): Overwriting $dst_file because it's older than $src_file"
                rm -- "$dst_file"
            else
                continue
            fi
        fi

        local newdir
        newdir="$(dirname "$dst_file")"
        if [[ ! -d "$newdir" ]]; then
            echo "$(date): Creating $newdir"
            mkdir -p "$newdir"
        fi

        transcode_file "$src_file" "$dst_file" "$job_count" "" &
        job_count=$((job_count + 1))

        while [[ "$(jobs | wc -l)" -ge "$total_numbers" ]]; do wait -n; done
    done 11< <(find "$SRC_DIR" -name "*.mkv" -type f -print0)
    if [[ -n "${DST_DIR_SMALL+x}" ]]; then
        while IFS= read -r -u 16 -d $'\0' src_file; do
            if [[ ! -f "$src_file" ]]; then continue; fi

            local dst_file="${src_file/"$SRC_DIR"/"$DST_DIR_SMALL"}"
            dst_file="${dst_file%.*}.mkv"
            if [[ -f "$dst_file" ]]; then
                if [[ "$dst_file" -ot "$src_file" ]]; then
                    echo "$(date): Overwriting $dst_file because it's older than $src_file"
                    rm -- "$dst_file"
                else
                    continue
                fi
            fi

            local newdir
            newdir="$(dirname "$dst_file")"
            if [[ ! -d "$newdir" ]]; then
                echo "$(date): Creating $newdir"
                mkdir -p "$newdir"
            fi

            transcode_file "$src_file" "$dst_file" "$job_count" "_small" &
            job_count=$((job_count + 1))

            while [[ "$(jobs | wc -l)" -ge "$total_numbers" ]]; do wait -n; done
        done 16< <(find "$SRC_DIR" -name "*.mkv" -type f -print0)
    fi
    while IFS= read -r -u 15 -d $'\0' src_file; do
        if [[ ! -f "$src_file" ]]; then continue; fi

        local dst_file="${src_file/\.mkv/_transcoded\.mkv}"
        if [ -f "$dst_file" ]; then
            continue
        fi

        transcode_file "$src_file" "$dst_file" "$job_count" "" &
        job_count=$((job_count + 1))

        while [[ "$(jobs | wc -l)" -ge "$total_numbers" ]]; do wait -n; done
    done 15< <(find "$INPLACE_DIR" \( -name "*.mkv" -and -type f \) -and \( -not -name "*_transcoded.mkv" \) -print0)
    wait

    echo "$(date): Trimming orphan outputs"
    while IFS= read -r -u 12 -d $'\0' file; do
        if [[ ! -f "$file" ]]; then continue; fi

        local oldpath="${file/"$DST_DIR"/"$SRC_DIR"}"
        oldpath="${oldpath%.*}.mkv"
        if [[ ! -f "$oldpath" ]]; then
            echo "    $(date): Removing $file"
            rm -- "$file"
        fi
    done 12< <(find "$DST_DIR" -name "*.mkv" -type f -print0)
    if [[ -n "${DST_DIR_SMALL+x}" ]]; then
        while IFS= read -r -u 17 -d $'\0' file; do
            if [[ ! -f "$file" ]]; then continue; fi

            local oldpath="${file/"$DST_DIR_SMALL"/"$SRC_DIR"}"
            oldpath="${oldpath%.*}.mkv"
            if [[ ! -f "$oldpath" ]]; then
                echo "    $(date): Removing $file"
                rm -- "$file"
            fi
        done 17< <(find "$DST_DIR_SMALL" -name "*.mkv" -type f -print0)
    fi

    echo "$(date): Checking corrupted outputs"
    while IFS= read -r -u 13 -d $'\0' file; do
        if [[ ! -f "$file" ]]; then continue; fi

        probe_file "$file" &
        while [[ "$(jobs | wc -l)" -ge "$TRANSCODE_CPU_THREADS" ]]; do wait -n; done
    done 13< <(find "$DST_DIR" -name "*.mkv" -type f -print0)
    if [[ -n "${DST_DIR_SMALL+x}" ]]; then
        while IFS= read -r -u 18 -d $'\0' file; do
            if [[ ! -f "$file" ]]; then continue; fi

            probe_file "$file" &
            while [[ "$(jobs | wc -l)" -ge "$TRANSCODE_CPU_THREADS" ]]; do wait -n; done
        done 18< <(find "$DST_DIR_SMALL" -name "*.mkv" -type f -print0)
    fi
    wait

    echo "$(date): Waiting for modification..."
    while read -r -u 14 line; do
        echo "    $(date): Detected event $line"
    done 14< <(inotifywait --include '.*\.mkv$' --recursive --event moved_to --event close_write --quiet --timeout 14400 "$SRC_DIR" "$INPLACE_DIR")
}

while true; do
    scan_folder
done
