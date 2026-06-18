#!/usr/bin/env bash
# Streams milestone transitions from the packer build log.
# One stdout line per state change; exits when the build finishes or the
# packer process disappears. Heartbeat every 45 min of no change.
LOG=/chungus/packer-2025-build.log
PAT='Connected to WinRM|Waiting for WinRM to become available|Reboot complete|Installing Visual Studio|Visual Studio Professional installed|Installing .NET 10|Installing latest stable PowerShell|Halting the virtual machine|Converting hard drive|Builds finished|artifacts of successful builds|errored after|Some builds did|Script exited with non-zero|Output directory|PACKER_EXIT='
prev=""
last_change=$(date +%s)
while true; do
  marker=$(grep -aE "$PAT" "$LOG" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' | tail -1)
  now=$(date +%s)
  if [ -n "$marker" ] && [ "$marker" != "$prev" ]; then
    echo "[$(date +%H:%M)] $marker"
    prev="$marker"; last_change=$now
  fi
  case "$marker" in *PACKER_EXIT=*) echo "[$(date +%H:%M)] BUILD FINISHED: $marker"; exit 0;; esac
  if ! pgrep -f "packer build" >/dev/null 2>&1; then
    sleep 5
    grep -aq "PACKER_EXIT=" "$LOG" 2>/dev/null || { echo "[$(date +%H:%M)] BUILD PROCESS GONE — no exit marker (possible crash/OOM)"; exit 1; }
  fi
  if [ $((now - last_change)) -ge 2700 ]; then
    echo "[$(date +%H:%M)] heartbeat — still at: ${prev:-<no milestone yet>} ($(((now-last_change)/60))min idle)"
    last_change=$now
  fi
  sleep 30
done
