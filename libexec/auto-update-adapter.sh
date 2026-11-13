#!/bin/bash
# Executed only after the manager has verified the upstream script's digest.
# Ask the actual upstream implementation for its decision, without updating or
# re-executing an installation. Only fixed, non-secret decision fields leave it.
source "$HOMEBREW_REPOSITORY/Library/Homebrew/utils/auto-update.sh"
needed=0
brew() {
  needed=1
  update_tap="${HOMEBREW_AUTO_UPDATE_TAP:-}"
  update_skip="${HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED:-}"
  update_core="${HOMEBREW_AUTO_UPDATE_CORE_TAP:-}"
  update_cask="${HOMEBREW_AUTO_UPDATE_CASK_TAP:-}"
}
exec() { :; }
setup-auto-update
auto-update "$@"
printf '%s\0' "${HOMEBREW_AUTO_UPDATE_CHECKED:-}" "$needed" \
  "${update_tap:-}" "${update_skip:-}" "${update_core:-}" "${update_cask:-}"
