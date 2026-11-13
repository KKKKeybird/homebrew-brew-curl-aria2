# Homebrew compatibility fixtures

These unmodified upstream files come from Homebrew/brew commit
`53c5856230b72e866ee4da77cfb9d39880291a99`; the auto-update adapter also checks the exact script SHA-256.

- `homebrew-auto-update.sh`: `Library/Homebrew/utils/auto-update.sh`
- `homebrew-curl.sh`: `Library/Homebrew/utils/curl.sh`
- `homebrew-tool.sh`: `Library/Homebrew/utils/tool.sh`

They exercise the actual upstream functions, rather than a replacement model.
See `HOMEBREW-LICENSE.txt` for the upstream BSD-2-Clause license.
