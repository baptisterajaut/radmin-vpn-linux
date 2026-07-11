#!/bin/bash
# health_check.sh - Diagnostic script for Radmin VPN Linux.
# Thin entry point: the logic lives in lib.sh's health_check() so it can be
# reused (e.g. from run*.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
health_check
