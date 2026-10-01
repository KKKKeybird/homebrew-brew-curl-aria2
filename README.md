# brew-curl-aria2

English · [简体中文](README.zh-CN.md)

`brew-curl-aria2` is a third-party Homebrew tap that routes eligible file downloads through aria2c. It uses multiple HTTP connections for a single file when the server supports range requests. Other curl operations stay with curl.

The project does not modify Homebrew's source code and does not run an aria2 daemon. It uses `HOMEBREW_CURL_PATH` to select a curl-compatible wrapper. Homebrew currently honors this setting on macOS, although its [environment reference](https://docs.brew.sh/Manpage#environment) documents the variable for Linux. Compatibility with future Homebrew releases is therefore not guaranteed.

## Installation

```sh
brew tap kkkkeybird/brew-curl-aria2
brew install brew-curl-aria2
brew-curl-aria2 enable
brew-curl-aria2 test
brew-curl-aria2 status
```

The formula installs aria2 as a dependency. Installation alone does not change Homebrew's download behavior; `enable` writes the wrapper path to Homebrew's user environment file. The location is `$XDG_CONFIG_HOME/homebrew/brew.env` when `XDG_CONFIG_HOME` is set, or `~/.homebrew/brew.env` otherwise.

Continue to use normal Homebrew commands, such as `brew upgrade --cask <name>`. Already cached files do not need another download.

## Request handling

The wrapper attempts aria2c for a new or resumed HTTP(S) file download with curl options it can translate. It defaults to eight connections and eight splits. Requests for headers, version information, request bodies, overwriting existing files without a resume request, and curl options with different semantics are forwarded unchanged to curl. Examples include explicit proxy or cookie settings, protocol and IP-family restrictions, and explicit numeric resume offsets. Homebrew’s automatic `--continue-at -` requests use aria2c.

aria2c downloads into a private `<output>.aria2-work` directory and publishes the file only after completion. It can resume a sequential curl partial or its own saved pieces. If aria2c fails, the wrapper retries the original command with curl against the untouched destination. If both fail, the saved aria2 pieces remain for the next attempt; they are removed after a successful download. If the server rejects range requests, aria2c retries from the beginning with one connection before falling back to curl. Legacy `.aria2` files are resumed with aria2c and are never handed to curl for continuation. Homebrew's own checksum verification still applies to downloaded formula and cask files.

Connection splitting can help when a server limits throughput per connection. It may provide no benefit when the network link is already saturated, and some servers do not support range requests. aria2c uses HTTP/1.1; curl may negotiate HTTP/2 or HTTP/3.

## Configuration

Set these variables in Homebrew's user environment file:

```sh
HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS=8
HOMEBREW_BREW_CURL_ARIA2_SPLITS=8
HOMEBREW_BREW_CURL_ARIA2_CHUNK=1M
```

For troubleshooting, set `HOMEBREW_BREW_CURL_ARIA2_DEBUG=1` to log routing decisions to stderr, or `HOMEBREW_BREW_CURL_ARIA2_LOG=/path/to/log` to append them to a file. `HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1` forces aria2c's console readout on; `0` turns it off. By default, download status (size, percentage, connections, speed, and ETA) is shown even through Homebrew's capture pipes, unless curl requests `--silent` or `--no-progress-meter`. Direct invocation of the wrapper also accepts the same names without the `HOMEBREW_` prefix.

`brew-curl-aria2 enable` refuses to replace an existing, different `HOMEBREW_CURL_PATH`. `disable` removes only this project's setting. If `HOMEBREW_FORCE_BREWED_CURL` is set, Homebrew gives the brewed curl precedence.

## Verification and development

```sh
brew-curl-aria2 status
brew-curl-aria2 test
bash test/shim.bash
python3 test/resume.py
```

The self-test downloads a small file and checks both aria2c routing and curl pass-through. CI on macOS and Linux runs both mock routing tests and real aria2c downloads against a local range server, verifying resumed files by SHA-256.

## Releases

Maintainers can run the **Release** workflow in GitHub Actions with a new `major.minor.patch` version. It runs the tests, builds a reproducible source archive, updates the CLI version and Formula URL/checksum, creates a version tag, and publishes the archive in a GitHub Release. The release workflow is intentional and does not run on every commit to `main`.

## Removal

```sh
brew-curl-aria2 disable
brew uninstall brew-curl-aria2
brew untap kkkkeybird/brew-curl-aria2
```

Run `disable` before uninstalling so that `HOMEBREW_CURL_PATH` does not point to a removed executable.

## License

MIT. This project is not affiliated with Homebrew or aria2.
