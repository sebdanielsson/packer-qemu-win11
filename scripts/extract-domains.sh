#!/usr/bin/env bash
# Extract the unique hostnames a build talked to (for firewall/proxy whitelisting)
# from the traffic pcap(s) QEMU's filter-dump captured during the build.
#
# Usage: scripts/extract-domains.sh /chungus/packer-output/traffic-*.pcap
# Captures DNS query names + TLS SNI (works with the maxlen=256 truncated pcap).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <pcap> [pcap ...]"; exit 1; }

if command -v tshark >/dev/null 2>&1; then
  for f in "$@"; do
    [ -f "$f" ] || { echo "skip (missing): $f" >&2; continue; }
    tshark -r "$f" -Y 'dns.flags.response==0' -T fields -e dns.qry.name 2>/dev/null
    tshark -r "$f" -T fields -e tls.handshake.extensions_server_name 2>/dev/null
  done | tr ',' '\n' | sed '/^$/d' | tr 'A-Z' 'a-z' | sort -u
else
  echo "tshark not installed; falling back to DNS-only via tcpdump." >&2
  echo "For full results (incl. TLS SNI): apt-get install -y tshark" >&2
  for f in "$@"; do
    [ -f "$f" ] || continue
    tcpdump -nn -r "$f" 'udp port 53' 2>/dev/null
  done | grep -oiE '\b(A|AAAA)\? [a-z0-9.-]+' | awk '{print $2}' | sed 's/\.$//' | tr 'A-Z' 'a-z' | sort -u
fi
