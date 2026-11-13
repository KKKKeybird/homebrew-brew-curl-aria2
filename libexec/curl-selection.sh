  # BEGIN brew-curl-aria2 selection v1
  # Only override the default selection for this plugin, never another override.
  local aria2_path="${HOMEBREW_BREW_CURL_ARIA2_SHIM:-}" aria2_version
  if [[ -z "${HOMEBREW_FORCE_BREWED_CURL}" && -n "${aria2_path}" &&
        "${HOMEBREW_CURL_PATH}" == "${aria2_path}" && -f "${aria2_path}" && -x "${aria2_path}" &&
        ! "${aria2_path}" -ef "${HOMEBREW_LIBRARY}/Homebrew/shims/shared/curl" ]]
  then
    if aria2_version="$("${aria2_path}" --version 2>/dev/null)" &&
       [[ "${aria2_version}" =~ ^curl\ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]
    then
      aria2_version="${BASH_REMATCH[1]}"
      if [[ "$(numeric "${aria2_version}")" -ge "$(numeric "${HOMEBREW_MINIMUM_CURL_VERSION}")" ]]
      then
        HOMEBREW_SELECTED_TOOL="${aria2_path}"
        HOMEBREW_SELECTED_TOOL_VERSION="${aria2_version}"
      fi
    fi
  fi
  # END brew-curl-aria2 selection v1
