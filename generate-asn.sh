#!/usr/bin/env bash

set -euo pipefail

DEFAULT_OUTPUT="/etc/haproxy/allowed.lst"
DEFAULT_LOGFILE="/var/log/update_allowlist.log"
LOCAL_OUTPUT_DEFAULT="allowed.lst"
LOCAL_LOGFILE_DEFAULT="update_allowlist.log"

ASNS="8359 13174 21365 30922 34351 3216 16043 16345 42842
31133 8263 6854 50928 48615 47395 47218 43841 42891 41976
35298 34552 31268 31224 31213 31208 31205 31195 31163 29648
25290 25159 24866 20663 20632 12396 202804 12958 15378 42437
48092 48190 41330 39374 13116 201776 206673 12389 35816 205638
214257 202498 203451 203561 47204"

OUTPUT="${OUTPUT:-}"
LOGFILE="${LOGFILE:-}"
LOG_TO_FILE=false
TMPFILE=""

usage() {
    cat <<'EOF'
Usage: bash generate-asn.sh [--output PATH] [--logfile PATH]

Options:
  --output PATH   Target file for generated IPv4 prefixes.
  --logfile PATH  Optional log file path.
  --help          Show this help.

If no paths are provided, the script uses:
  - /etc/haproxy/allowed.lst and /var/log/update_allowlist.log when writable
  - ./allowed.lst and ./update_allowlist.log otherwise
EOF
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" >&2
    if [[ "$LOG_TO_FILE" == true ]]; then
        printf '%s\n' "$message" >> "$LOGFILE"
    fi
}

cleanup() {
    if [[ -n "$TMPFILE" && -f "$TMPFILE" ]]; then
        rm -f "$TMPFILE"
    fi
}

trap cleanup EXIT

can_write_path() {
    local path="$1"
    local target_dir

    target_dir="$(dirname "$path")"

    mkdir -p "$target_dir" 2>/dev/null || return 1
    touch "$path" 2>/dev/null || return 1
}

resolve_path() {
    local preferred="$1"
    local fallback="$2"
    local selected="$preferred"

    if [[ -z "$selected" ]]; then
        selected="$fallback"
    fi

    if can_write_path "$selected"; then
        printf '%s\n' "$selected"
        return 0
    fi

    if can_write_path "$fallback"; then
        printf '%s\n' "$fallback"
        return 0
    fi

    echo "Unable to write to '$selected' or fallback '$fallback'" >&2
    exit 1
}

ensure_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 1; }
                OUTPUT="$2"
                shift 2
                ;;
            --logfile)
                [[ $# -ge 2 ]] || { echo "--logfile requires a value" >&2; exit 1; }
                LOGFILE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    ensure_command whois
    ensure_command grep
    ensure_command awk
    ensure_command sort
    ensure_command mv
    ensure_command wc
    ensure_command mktemp

    if [[ -n "$OUTPUT" ]]; then
        OUTPUT="$(resolve_path "$OUTPUT" "$LOCAL_OUTPUT_DEFAULT")"
    else
        OUTPUT="$(resolve_path "$DEFAULT_OUTPUT" "$LOCAL_OUTPUT_DEFAULT")"
    fi

    if [[ -n "$LOGFILE" ]]; then
        LOGFILE="$(resolve_path "$LOGFILE" "$LOCAL_LOGFILE_DEFAULT")"
    else
        LOGFILE="$(resolve_path "$DEFAULT_LOGFILE" "$LOCAL_LOGFILE_DEFAULT")"
    fi
    LOG_TO_FILE=true

    TMPFILE="$(mktemp "${OUTPUT}.tmp.XXXXXX")"

    log "Starting allowlist update"
    log "Output file: $OUTPUT"
    if [[ "$LOG_TO_FILE" == true ]]; then
        log "Log file: $LOGFILE"
    else
        log "Log file disabled: no writable location available"
    fi

    : > "$TMPFILE"

    for ASN in $ASNS; do
        log "Fetching AS$ASN"
        RESULT="$(whois -h whois.radb.net -- "-i origin AS$ASN" 2>&1 || true)"

        if echo "$RESULT" | grep -Eiq "connect|timeout|refused|error"; then
            log "ERROR AS$ASN: $RESULT"
            sleep 2
            continue
        fi

        PREFIXES="$(echo "$RESULT" | grep "^route:" | awk '{print $2}' || true)"
        COUNT="$(echo "$PREFIXES" | grep -c '.' || true)"

        if [[ "$COUNT" -eq 0 ]]; then
            log "WARNING AS$ASN: 0 prefixes returned"
        else
            printf '%s\n' "$PREFIXES" >> "$TMPFILE"
            log "OK AS$ASN: $COUNT prefixes"
        fi

        sleep 0.5
    done

    if ! grep -v ':' "$TMPFILE" | grep -E '^[0-9]' | sort -u > "${TMPFILE}.sorted"; then
        : > "${TMPFILE}.sorted"
    fi
    mv "${TMPFILE}.sorted" "$OUTPUT"

    local total
    total="$(wc -l < "$OUTPUT")"
    log "Done: $total networks written to $OUTPUT"
}

main "$@"
