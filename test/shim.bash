#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/opt/curl/bin" "$fixture/bin" "$fixture/config/homebrew"

cat >"$fixture/opt/curl/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CURL_ARGS"
[ "${TEST_CURL_FAIL:-0}" = 0 ] || exit 22
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
rm -f "$dir/$out.aria2"
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
reset() { rm -rf "$fixture/.brew-curl-aria2/out"; rm -f "$TEST_CURL_ARGS" "$TEST_ARIA2_ARGS" "$fixture/out" "$fixture/out.aria2"; }
assert_aria2() { [ -f "$TEST_ARIA2_ARGS" ] && [ ! -f "$TEST_CURL_ARGS" ] || fail "$1"; }
assert_curl() { [ -f "$TEST_CURL_ARGS" ] && [ ! -f "$TEST_ARIA2_ARGS" ] || fail "$1"; }

reset
"$shim" --disable --cookie /dev/null --output "$fixture/out" --location https://example.test/file
assert_aria2 'ordinary Homebrew download should use aria2c'
[ "$(cat "$fixture/out")" = 'aria2 result' ] || fail 'aria2c output missing'
grep -q '^--show-console-readout=true$' "$TEST_ARIA2_ARGS" || fail 'default download hides progress'
grep -q '^--load-cookies=/dev/null$' "$TEST_ARIA2_ARGS" || fail 'empty cookie jar not forwarded'

# Homebrew pipes child output even when its own terminal shows progress.
# These invocations run without a PTY, reproducing the missing meter.
reset
"$shim" --progress-bar --output "$fixture/out" --location https://example.test/file
assert_aria2 'piped download should use aria2c'
grep -q '^--show-console-readout=true$' "$TEST_ARIA2_ARGS" || fail 'piped download hides progress'
for option in '--silent' '--no-progress-meter' '--silent --progress-bar'; do
  reset
  read -r -a extra <<<"$option"
  "$shim" --output "$fixture/out" --location "${extra[@]}" https://example.test/file
  grep -q '^--show-console-readout=false$' "$TEST_ARIA2_ARGS" || fail 'quiet download shows progress'
done
reset
HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1 "$shim" --silent --output "$fixture/out" --location https://example.test/file
grep -q '^--show-console-readout=true$' "$TEST_ARIA2_ARGS" || fail 'forced progress not enabled'
reset
HOMEBREW_BREW_CURL_ARIA2_PROGRESS=0 "$shim" --progress-bar --output "$fixture/out" --location https://example.test/file
grep -q '^--show-console-readout=false$' "$TEST_ARIA2_ARGS" || fail 'progress override not disabled'

for option in '--proxy http://proxy.test' '--cookie session=secret' '--proto-redir =https' '--ipv4' '--compressed' '--max-time 20' '--continue-at 12'; do
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
printf 'existing' >"$fixture/out"
"$shim" --output "$fixture/out" --location --continue-at - https://example.test/file
assert_aria2 'automatic curl resume should use aria2c'
[ "$(cat "$fixture/out")" = 'aria2 result' ] || fail 'resumed file not published'
[ ! -e "$fixture/.brew-curl-aria2/out" ] || fail 'successful resume left workdir'

reset
printf 'existing' >"$fixture/out"
TEST_ARIA2_FAIL=1 TEST_CURL_FAIL=1 "$shim" --output "$fixture/out" --location -C - https://example.test/file && fail 'failed download returned success'
[ "$(cat "$fixture/out")" = 'existing' ] || fail 'aria2 modified original curl partial'
[ -f "$fixture/.brew-curl-aria2/out/data.aria2" ] || fail 'failed download lost aria2 pieces'
rm -f "$TEST_ARIA2_ARGS" "$TEST_CURL_ARGS"
"$shim" --output "$fixture/out" --location -C - https://example.test/file
assert_aria2 'saved pieces should use aria2c on retry'
[ "$(cat "$fixture/out")" = 'aria2 result' ] || fail 'saved pieces not published'

reset
TEST_ARIA2_FAIL=1 TEST_CURL_FAIL=1 "$shim" --output "$fixture/out" --location https://example.test/file && fail 'failed fresh download returned success'
[ ! -e "$fixture/out" ] || fail 'sparse file exposed to Homebrew'
rm -f "$TEST_ARIA2_ARGS" "$TEST_CURL_ARGS"
"$shim" --output "$fixture/out" --location https://example.test/file
assert_aria2 'fresh retry should resume saved pieces'

reset
printf 'legacy pieces' >"$fixture/out"
printf 'state' >"$fixture/out.aria2"
TEST_ARIA2_FAIL=1 "$shim" --output "$fixture/out" --location -C - https://example.test/file && fail 'failed legacy resume returned success'
[ ! -e "$TEST_CURL_ARGS" ] || fail 'curl tried to resume legacy pieces'
[ "$(cat "$fixture/out")" = 'legacy pieces' ] || fail 'legacy pieces changed before publication'
"$shim" --output "$fixture/out" --location -C - --ipv4 https://example.test/file && fail 'unsupported legacy resume returned success'
[ ! -e "$TEST_CURL_ARGS" ] || fail 'unsupported request sent legacy pieces to curl'
"$shim" --output "$fixture/out" --location -C - https://example.test/file
[ ! -e "$fixture/out.aria2" ] || fail 'successful legacy resume left stale state'

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

# Legacy state must leave Homebrew's hash-prefix cache namespace, with all
# bytes preserved. A repeated repair must be harmless.
export TEST_CACHE="$fixture/cache"
mkdir -p "$TEST_CACHE/downloads"
cat >"$fixture/bin/brew" <<'EOF'
#!/bin/bash
printf '%s\n' "$TEST_CACHE"
EOF
chmod +x "$fixture/bin/brew"
legacy_name="$(printf '%064d' 0)--file.dmg.incomplete.aria2-work"
legacy="$TEST_CACHE/downloads/$legacy_name"
mkdir "$legacy"
printf 'pieces' >"$legacy/data"
printf 'state' >"$legacy/data.aria2"
printf 'https://example.test/file' >"$legacy/url"
"$ctl" repair-cache >"$fixture/repair.out"
[ ! -e "$legacy" ] || fail 'legacy directory still matches Homebrew cache glob'
[ "$(cat "$TEST_CACHE/downloads/.brew-curl-aria2/${legacy_name%.aria2-work}/data")" = pieces ] || fail 'repair discarded pieces'
"$ctl" repair-cache >"$fixture/repair.out"
grep -q '0' "$fixture/repair.out" || fail 'repeated repair not harmless'

printf 'PASS: routing, fallback cleanup, and config preservation\n'
