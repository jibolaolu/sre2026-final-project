#!/usr/bin/env bash
# recovery.sh — Quick recovery after a reboot or minikube restart.
# Calls startup.sh --skip-build (no image rebuild — uses existing images).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/startup.sh" --skip-build "$@"
