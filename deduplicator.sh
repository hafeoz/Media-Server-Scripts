#!/bin/sh
# Deduplicate media using czkawka
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

deduplicate() {
    echo "Deduplicate (Hash) at $1 skipping $2 started at $(date)"
    czkawka_cli dup --directories "$1" --excluded-directories "$2" --delete-method "$3" --use-prehash-cache --hash-type xxh3
    echo "Deduplicate (Image) at $1 skipping $2 started at $(date)"
    czkawka_cli image --directories "$1" --excluded-directories "$2" --delete-method "$3" --similarity-preset Original --hash-alg DoubleGradient --image-filter Lanczos3
    echo "Deduplicate (Music) at $1 skipping $2 started at $(date)"
    czkawka_cli music --directories "$1" --excluded-directories "$2" --delete-method "$3" --search-method CONTENT --maximum-difference 0.5 --minimum-segment-duration 120
    echo "Deduplicate (Video) at $1 skipping $2 started at $(date)"
    czkawka_cli video --directories "$1" --excluded-directories "$2" --delete-method "$3" --tolerance 3 2>&1 | grep -v "Failed to hash file, reason Too short:"
    echo "Deduplicate completed at $(date)"
}

while true; do
    if [ -f "${CONFIG_FILE-/etc/deduplicator.conf}" ]; then
        # shellcheck disable=SC1090
        . "${CONFIG_FILE-/etc/deduplicator.conf}"
    fi
    sleep 24h
done
