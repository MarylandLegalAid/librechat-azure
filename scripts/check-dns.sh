#!/usr/bin/env bash
#
# Is a DNS change published widely enough to ask Let's Encrypt for a
# certificate? Run before any deploy that makes Caddy issue one for a hostname
# whose address just changed.
#
#   scripts/check-dns.sh <hostname> <expected IPv4> [rounds] [percent]
#
#   scripts/check-dns.sh code.example.org 203.0.113.10
#
# Asks every AUTHORITATIVE nameserver for the zone, `rounds` times each
# (default 12), and passes only if at least `percent` of all answers (default
# 95) are the expected address. Exit 0 = go, 1 = wait, 2 = usage.
#
# Why sample instead of asking once: large DNS providers run each nameserver as
# many anycast nodes, and while a change publishes, the SAME nameserver answers
# old and new alternately. A single "all nameservers agree" check can pass by
# luck and then break. Failed Let's Encrypt validations are capped at five per
# hostname per hour, so deploying into a half-published zone costs an hour.
# docs/modules/migrating-an-existing-install.md tells the story.

set -euo pipefail

HOST="${1:-}"; EXPECTED="${2:-}"; ROUNDS="${3:-12}"; PERCENT="${4:-95}"
if [ -z "$HOST" ] || [ -z "$EXPECTED" ]; then
  sed -n '7,9p' "$0" >&2
  exit 2
fi
command -v dig >/dev/null 2>&1 || { echo "check-dns.sh needs dig (dnsutils / bind-utils)" >&2; exit 2; }

# The zone's nameservers: walk up from the hostname until a name has NS records.
zone="$HOST"
nameservers=""
while [ -n "$zone" ] && [ "${zone#*.}" != "$zone" ]; do
  nameservers="$(dig +short NS "$zone" | sed 's/\.$//')"
  [ -n "$nameservers" ] && break
  zone="${zone#*.}"
done
if [ -z "$nameservers" ]; then
  echo "could not find the nameservers for $HOST" >&2
  exit 2
fi

total=0
matched=0
declare -A seen=()
for _ in $(seq 1 "$ROUNDS"); do
  for ns in $nameservers; do
    answer="$(dig +short +time=3 +tries=1 A "$HOST" @"$ns" | grep -E '^[0-9.]+$' | head -1 || true)"
    answer="${answer:-<none>}"
    total=$((total + 1))
    seen["$answer"]=$(( ${seen["$answer"]:-0} + 1 ))
    [ "$answer" = "$EXPECTED" ] && matched=$((matched + 1))
  done
done

echo "$HOST via $(echo "$nameservers" | tr '\n' ' ')"
for answer in "${!seen[@]}"; do
  printf '  %4d  %s%s\n' "${seen[$answer]}" "$answer" "$([ "$answer" = "$EXPECTED" ] && echo '  (expected)')"
done

share=$((matched * 100 / total))
if [ "$share" -ge "$PERCENT" ]; then
  echo "GO: $share% of $total answers are $EXPECTED"
  exit 0
fi
echo "WAIT: $share% of $total answers are $EXPECTED (need $PERCENT%). Try again in a few minutes."
exit 1
