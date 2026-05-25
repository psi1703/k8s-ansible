#!/usr/bin/env bash
# Shared functions for install-otp-relay-k8s.sh. Source this file; do not execute it directly.

is_debian_family() {
  case "${OS_ID:-} ${OS_LIKE:-}" in
    *debian*|*ubuntu*) return 0 ;;
    *) return 1 ;;
  esac
}
