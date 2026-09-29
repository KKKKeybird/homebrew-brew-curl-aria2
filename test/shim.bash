#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/opt/curl/bin" "$fixture/bin" "$fixture/config/homebrew"

cat >"$fixture/opt/curl/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CURL_ARGS"
while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o) printf 'curl result' >"$2"; break ;;
  esac
  shift
done
EOF
cat >"$fixture/bin/aria2c" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_ARIA2_ARGS"
dir="" out=""
for arg in "$@"; do
  case "$arg" in
    --dir=*) dir="${arg#--dir=}" ;;
    --out=*) out="${arg#--out=}" ;;
  esac
done
if [ "${TEST_ARIA2_FAIL:-0}" = 1 ]; then
  printf 'partial' >"$dir/$out"
  printf 'state' >"$dir/$out.aria2"
  exit 1
fi
printf 'aria2 result' >"$dir/$out"
EOF
chmod +x "$fixture/opt/curl/bin/curl" "$fixture/bin/aria2c"

export HOMEBREW_PREFIX="$fixture"
export XDG_CONFIG_HOME="$fixture/config"
export PATH="$fixture/bin:$PATH"
export TEST_CURL_ARGS="$fixture/curl.args"
export TEST_ARIA2_ARGS="$fixture/aria2.args"
shim="$repo/libexec/curl-aria2"
ctl="$repo/bin/brew-curl-aria2"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
reset() { rm -f "$TEST_CURL_ARGS" "$TEST_ARIA2_ARGS" "$fixture/out" "$fixture/out.aria2"; }
assert_aria2() { [ -f "$TEST_ARIA2_ARGS" ] && [ ! -f "$TEST_CURL_ARGS" ] || fail "$1"; }
assert_curl() { [ -f "$TEST_CURL_ARGS" ] && [ ! -f "$TEST_ARIA2_ARGS" ] || fail "$1"; }

reset
"$shim" --disable --cookie /dev/null --output "$fixture/out" --location https://example.test/file
assert_aria2 'ordinary Homebrew download should use aria2c'
[ "$(cat "$fixture/out")" = 'aria2 result' ] || fail 'aria2c output missing'
grep -q '^--load-cookies=/dev/null$' "$TEST_ARIA2_ARGS" || fail 'empty cookie jar not forwarded'

for option in '--proxy http://proxy.test' '--cookie session=secret' '--proto-redir =https' '--ipv4' '--compressed' '--max-time 20' '--continue-at -'; do
  reset
  # Deliberately split each fixed fixture argument into words.
  read -r -a extra <<<"$option"
  "$shim" --output "$fixture/out" --location "${extra[@]}" https://example.test/file
  assert_curl "$option should use curl"
done

reset
"$shim" --output "$fixture/out" --location https://example.test/one https://example.test/two
assert_curl 'multiple URLs should use curl'

reset
printf 'existing' >"$fixture/out"
"$shim" --output "$fixture/out" --location https://example.test/file
assert_curl 'existing destination should use curl'

reset
TEST_ARIA2_FAIL=1 "$shim" --output "$fixture/out" --location https://example.test/file
[ -f "$TEST_CURL_ARGS" ] && [ -f "$TEST_ARIA2_ARGS" ] || fail 'aria2c failure should retry curl'
[ "$(cat "$fixture/out")" = 'curl result' ] || fail 'curl did not replace failed aria2c output'
[ ! -e "$fixture/out.aria2" ] || fail 'failed aria2c state left behind'

env_file="$XDG_CONFIG_HOME/homebrew/brew.env"
printf 'HOMEBREW_CURL_PATH=/another/curl\nOTHER_SETTING=1\n' >"$env_file"
"$ctl" enable >"$fixture/ctl.out" 2>&1 && fail 'enable replaced another curl setting'
grep -q '^HOMEBREW_CURL_PATH=/another/curl$' "$env_file" || fail 'enable changed existing curl setting'
"$ctl" disable >"$fixture/ctl.out"
grep -q '^HOMEBREW_CURL_PATH=/another/curl$' "$env_file" || fail 'disable removed another curl setting'

printf 'OTHER_SETTING=1\n' >"$env_file"
"$ctl" enable >"$fixture/ctl.out"
"$ctl" enable >"$fixture/ctl.out"
[ "$(grep -c '^HOMEBREW_CURL_PATH=' "$env_file")" = 1 ] || fail 'enable duplicated curl setting'
"$ctl" disable >"$fixture/ctl.out"
grep -q '^OTHER_SETTING=1$' "$env_file" || fail 'disable removed another setting'
! grep -q '^HOMEBREW_CURL_PATH=' "$env_file" || fail 'disable left its curl setting'

printf 'PASS: routing, fallback cleanup, and config preservation\n'
