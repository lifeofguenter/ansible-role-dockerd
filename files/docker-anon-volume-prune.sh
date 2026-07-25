#!/usr/bin/env bash
#
# Prune detached anonymous Docker volumes older than 1h.
#
# A volume is removed only when ALL of these hold:
#   * detached       - dangling=true, i.e. not referenced by any container
#                      (running OR stopped). `docker volume rm` (without -f)
#                      also refuses an in-use volume as a final safety net.
#   * anonymous      - 64-hex-character name. Named volumes never match this,
#                      so their data is never touched. (This is more robust
#                      than the com.docker.volume.anonymous label, which has
#                      historically been unset on compose-created volumes.)
#   * not protected  - has no "keepme" label.
#   * older than 1h  - avoids racing a volume that was just created but not
#                      yet attached to its container.

# Non-zero exits are normal control flow here (grep exits 1 when nothing
# matches, docker exits 1 when the daemon is down), and both must be a harmless
# no-op rather than a failure -- so deliberately NO `set -e` / `-o pipefail`.
# Errors are handled per command below (|| continue, || true, [ -n ... ] guards).
# `set -u` still guards against undefined-variable typos in future edits.
set -u

# The only platform-specific gotcha is turning an RFC3339 timestamp into epoch
# seconds: GNU date wants `date -d`, BSD/macOS date wants `date -j -f`. To keep
# ONE code path that runs identically on Linux (cron) and macOS (local testing),
# the conversion is done in awk (POSIX string/int ops only, no date parsing).
#
# RFC3339 (e.g. 2026-07-25T13:30:00+02:00, or ...Z) -> epoch seconds.
to_epoch() {
  printf '%s\n' "$1" | awk '
    {
      s = $0
      sub(/\.[0-9]+/, "", s)                        # drop fractional seconds
      if (s ~ /[Zz]$/) { off = 0; sub(/[Zz]$/, "", s) }
      else {                                         # trailing +HH:MM / -HH:MM
        o = substr(s, length(s) - 5)
        off = ((substr(o,2,2)+0)*3600 + (substr(o,5,2)+0)*60) * (substr(o,1,1)=="-" ? -1 : 1)
        s = substr(s, 1, length(s) - 6)
      }
      y=substr(s,1,4)+0; mo=substr(s,6,2)+0; d=substr(s,9,2)+0
      h=substr(s,12,2)+0; mi=substr(s,15,2)+0; se=substr(s,18,2)+0
      yy = (mo <= 2) ? y - 1 : y                     # days-from-civil (Hinnant)
      era = int(yy / 400); yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      print days * 86400 + h * 3600 + mi * 60 + se - off
    }'
}

cutoff=$(( $(date +%s) - 3600 ))

docker volume ls -q -f dangling=true 2>/dev/null | grep -E '^[0-9a-f]{64}$' | while read -r vol; do
  meta="$(docker volume inspect -f '{{ .CreatedAt }}|{{ json .Labels }}' "$vol" 2>/dev/null)" || continue
  created="${meta%%|*}"
  labels="${meta#*|}"

  # Skip volumes protected with the keepme label.
  echo "$labels" | grep -q '"keepme"' && continue

  # Skip volumes newer than the cutoff.
  [ -n "$created" ] || continue
  ts="$(to_epoch "$created")"
  [ -n "$ts" ] || continue
  [ "$ts" -lt "$cutoff" ] || continue

  docker volume rm "$vol" >/dev/null 2>&1 || true
done
