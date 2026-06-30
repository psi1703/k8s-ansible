#!/usr/bin/env bash
# Shared OS helper functions for the OTP Relay bundle-only release builder.
# Source this file; do not execute it directly.
#
# This file must stay non-mutating:
#   - no apt-get
#   - no package installation
#   - no K3s installation
#   - no service changes
#   - no network/firewall changes
#
# The production server receives only the finished bundle.

is_debian_family() {
  case "${OS_ID:-} ${OS_LIKE:-}" in
    *debian*|*ubuntu*) return 0 ;;
    *) return 1 ;;
  esac
}
