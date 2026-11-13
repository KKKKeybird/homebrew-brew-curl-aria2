# Loaded by the marked block installed by `brew-curl-aria2 enable`.
# Capture absolute paths now: never resolve brew through this function again.
brew() {
  if [ -n "${ZSH_VERSION:-}" ]; then emulate -L sh; fi
  if [ "${BREW_CURL_ARIA2_WRAPPER_ACTIVE:-}" = 1 ]; then
    command "$BREW_CURL_ARIA2_REAL_BREW" "$@"
  elif [ -x "$BREW_CURL_ARIA2_CONTROL" ]; then
    BREW_CURL_ARIA2_WRAPPER_LOADED=1 "$BREW_CURL_ARIA2_CONTROL" wrap "$@"
  else
    command "$BREW_CURL_ARIA2_REAL_BREW" "$@"
  fi
}
export BREW_CURL_ARIA2_WRAPPER_LOADED=1
