#!/usr/bin/env bash
# Logged adb wrapper — appends every invocation + output to adb_session.log.
LOG="$(dirname "$0")/../run/adb_session.log"; mkdir -p "$(dirname "$LOG")"
echo "===== $(date -Is) adb $*" >> "$LOG"
~/Android/Sdk/platform-tools/adb "$@" 2>&1 | tee -a "$LOG"; exit ${PIPESTATUS[0]}
