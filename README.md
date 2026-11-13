# brew-curl-aria2

English · [简体中文](README.zh-CN.md)

`brew-curl-aria2` is a third-party Homebrew tap that routes eligible file downloads through aria2c. It uses multiple HTTP connections for a single file when the server supports range requests. Other curl operations stay with curl.

The project uses a curl-compatible shim and does not run a daemon. On Homebrew versions that treat `HOMEBREW_CURL_PATH` as a suggestion, `enable` adds a reversible, plugin-specific patch to `setup_curl()`. A terminal wrapper coordinates Homebrew updates and reapplies the patch before installation. Unsupported upstream source changes are reported and use ordinary curl.

## Installation

```sh
brew tap kkkkeybird/brew-curl-aria2
brew install brew-curl-aria2
brew-curl-aria2 enable
brew-curl-aria2 test
brew-curl-aria2 status
```

The formula installs aria2 as a dependency. Installation alone does not change Homebrew's download behavior; `enable` writes the wrapper path to Homebrew's user environment file. The location is `$XDG_CONFIG_HOME/homebrew/brew.env` when `XDG_CONFIG_HOME` is set, or `~/.homebrew/brew.env` otherwise.

Open a new terminal after enabling (or reload your shell startup file), then use normal Homebrew commands such as `brew upgrade --cask <name>`. Already cached files do not need another download.

`enable` adds marked loader blocks to zsh's `.zshrc` (under `ZDOTDIR` when set), bash's `.bashrc`, and the active bash login file. `disable` removes these blocks and only this project's source patch and environment entries, preserving unrelated changes. A wrapper already loaded in a disabled shell passes commands through.

For terminal `install`, `upgrade`, `update`/`up`, and `update-reset`, the wrapper serializes the update/patch/command lifecycle with a repository lock. It removes its own patch before updating, then reapplies it against the new source. Automatic update decisions use a digest-verified adapter to Homebrew's own interval and tap rules; unknown versions keep native update behaviour and restore the patch after the command, so aria2 is not guaranteed during that command. Explicit update failures retain their exit codes; automatic update failures are reported before continuing with available data.

Direct `/opt/homebrew/bin/brew` calls, GUI calls, other commands and calls with leading global options bypass automatic repair. They may still use aria2 while the patch is present. There is no background watcher. Run `brew-curl-aria2 repair-homebrew` to restore a missing patch manually. Do not uninstall without disabling first.

The patch respects `HOMEBREW_FORCE_BREWED_CURL`. `status` reports enable intent, the observed shell wrapper, patch presence and Homebrew's actual selected curl. Selecting the shim does not guarantee every request uses aria2: unsupported semantics still fall back to curl.

## Request handling

The wrapper attempts aria2c for a new or resumed HTTP(S) file download with curl options it can translate. It defaults to eight connections and eight splits. Requests for headers, version information, request bodies, overwriting existing files without a resume request, and curl options with different semantics are forwarded unchanged to curl. Examples include explicit proxy or cookie settings, protocol and IP-family restrictions, and explicit numeric resume offsets. Homebrew’s automatic `--continue-at -` requests use aria2c.

aria2c downloads into a private `<output directory>/.brew-curl-aria2/<output filename>` directory and publishes the completed file only after completion. For Homebrew `.incomplete` destinations, a small bridge mirrors only confirmed, contiguous pieces into the destination during the transfer so Homebrew can read native progress. It can resume a sequential curl partial or its own saved pieces. If aria2c fails, the wrapper retries the original command with curl against the destination containing only a valid sequential partial. If both fail, the saved aria2 pieces remain for the next attempt; they are removed after a successful download. A metadata request and a one-byte range probe verify the size and actual `206 Content-Range` support before parallel downloads. With valid metadata, aria2 uses HEAD and HTTP pipelining to request each piece with explicit start and end offsets, consuming each response in full rather than requesting a long tail and stopping early. Missing metadata or an unverified range response selects a single aria2 connection; a later range rejection restarts a single stream before falling back to curl. The probe adds HTTP requests, and an ignored Range can still cause discarded upstream data during that single probe. This cannot correct a proxy provider’s accounting errors. Legacy `.aria2` files are resumed with aria2c and are never handed to curl for continuation. Homebrew's own checksum verification still applies to downloaded formula and cask files.

Connection splitting can help when a server limits throughput per connection. It may provide no benefit when the network link is already saturated, and some servers do not support range requests. aria2c uses HTTP/1.1; curl may negotiate HTTP/2 or HTTP/3.

If upgrading from 0.2.1 or 0.2.2 after an interrupted download, run `brew-curl-aria2 repair-cache` once before retrying Homebrew. It relocates recognized legacy `.incomplete.aria2-work` directories out of Homebrew's completed-file lookup while preserving their pieces. The new layout prevents this directory/file collision.

## Configuration

Homebrew's parallel queue draws its meter from the `.incomplete` download file. The wrapper integrates a bridge directly at `HOMEBREW_CURL_PATH`: it reads aria2's saved piece map and appends only the actual completed prefix to that file. Sparse pieces remain private, and the full file is published only after aria2 succeeds. Normal `brew upgrade`, `install`, and `fetch` therefore keep concurrent package downloads and show Homebrew's native byte counts and progress bars. No shell function, startup-file edit, daemon, or Homebrew source patch is required.

Native progress represents the completed contiguous prefix and can lag behind pieces downloaded elsewhere in the file. The bridge disables aria2's disk cache and prefers pieces in order while retaining multiple connections; mirroring adds disk writes and temporary disk use. It uses Homebrew's already selected Ruby runtime, validates aria2's v1 HTTP control-file format, and skips progress mirroring if the runtime or supported state is unavailable. Downloading and final verification continue normally. Homebrew's native meter does not display aria2's connection count, speed, or ETA; the detailed aria2 readout is still available for serial downloads. You can disable mirroring with `HOMEBREW_BREW_CURL_ARIA2_NATIVE_PROGRESS=0`.

Set these variables in Homebrew's user environment file:

```sh
HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS=8
HOMEBREW_BREW_CURL_ARIA2_SPLITS=8
HOMEBREW_BREW_CURL_ARIA2_CHUNK=1M
```

For troubleshooting, set `HOMEBREW_BREW_CURL_ARIA2_DEBUG=1` to log routing decisions to stderr, or `HOMEBREW_BREW_CURL_ARIA2_LOG=/path/to/log` to append them to a file. `HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1` forces aria2c's console readout on; `0` turns it off. Carriage-return readouts are relayed as newline-terminated records so Homebrew displays them during the transfer; progress-bar requests redraw one row. By default, download status (size, percentage, connections, speed, and ETA) is shown even through Homebrew's capture pipes, unless curl requests `--silent` or `--no-progress-meter`. Direct invocation of the wrapper also accepts the same names without the `HOMEBREW_` prefix.

`brew-curl-aria2 enable` refuses to replace an existing, different `HOMEBREW_CURL_PATH`. `disable` removes only this project's setting. If `HOMEBREW_FORCE_BREWED_CURL` is set, Homebrew gives the brewed curl precedence.

## Verification and development

```sh
brew-curl-aria2 status
brew-curl-aria2 test
bash test/shim.bash
python3 test/resume.py
python3 test/bounded_ranges.py
ruby test/contiguous_progress.rb
python3 test/parallel_progress.py
```

The self-test checks routing and curl pass-through, then fetches a fresh resource through real Homebrew and verifies aria2 invocation and SHA-256 against an independent curl download. CI on macOS and Linux runs both mock routing tests and real aria2c downloads against a local range server, verifying resumed files by SHA-256.

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

Certificate directories containing hashed CA/CRL entries and curl header-file options (including `--header @-`) are delegated unchanged to curl. Homebrew's injected bundle-parent CA directory is accepted only when it adds no hashed trust entries; the bundle is passed to aria2. Authentication headers read from stdin are never consumed or logged by the shim.

Inline Authorization, Proxy-Authorization and Cookie headers also use curl to preserve its cross-origin redirect restrictions. Consequently, authenticated GHCR bottle requests may intentionally use curl.
