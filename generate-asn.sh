#!/bin/bash

OUTPUT="/etc/haproxy/allowed.lst"
LOGFILE="/var/log/update_allowlist.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

ASNS="8359 13174 21365 30922 34351 3216 16043 16345 42842
31133 8263 6854 50928 48615 47395 47218 43841 42891 41976
35298 34552 31268 31224 31213 31208 31205 31195 31163 29648
25290 25159 24866 20663 20632 12396 202804 12958 15378 42437
48092 48190 41330 39374 13116 201776 206673 12389 35816 205638
214257 202498 203451 203561 47204"

> $OUTPUT
log "Starting allowlist update"

for ASN in $ASNS; do
    echo -n "Fetching AS$ASN... "
    RESULT=$(whois -h whois.radb.net -- "-i origin AS$ASN" 2>&1)

    if echo "$RESULT" | grep -q "connect\|timeout\|refused\|error"; then
        log "ERROR AS$ASN: $RESULT"
        echo "ERROR"
        sleep 2
        continue
    fi

    PREFIXES=$(echo "$RESULT" | grep "^route:" | awk '{print $2}')
    COUNT=$(echo "$PREFIXES" | grep -c '.' || true)
    echo "$COUNT prefixes"

    if [ $COUNT -eq 0 ]; then
        log "WARNING AS$ASN: 0 prefixes returned"
    else
        echo "$PREFIXES" >> $OUTPUT
        log "OK AS$ASN: $COUNT prefixes"
    fi

    sleep 0.5
done

grep -v ':' $OUTPUT | grep -E '^[0-9]' | sort -u > ${OUTPUT}.tmp
mv ${OUTPUT}.tmp $OUTPUT

TOTAL=$(wc -l < $OUTPUT)
log "Done: $TOTAL networks written to $OUTPUT"
echo "Done: $TOTAL networks written to $OUTPUT"