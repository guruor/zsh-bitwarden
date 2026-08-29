# Repository Guidance

- This is a standalone Zsh/Oh My Zsh plugin, not a package-managed project; there is no build, dependency-install, lint, or formatter workflow.
- `zsh-bitwarden.plugin.zsh` is the plugin-manager loader; keep its standard path resolution intact. It adds `completions/` to `fpath` and sources `zsh-bitwarden.zsh`; `default-headers.csv` supplies TSV/fzf display headers.
- Runtime requirements are `zsh`, Bitwarden CLI (`bw`), `jq`, and `fzf`; install/load the plugin as documented in `INSTALL.md` before manually exercising commands. `bwssh` additionally requires native OpenSSH `ssh-add` and `ssh-keygen`.
- Most commands start or use `bw serve` through a local HTTP API on `localhost:8087`; a real Bitwarden vault and unlock interaction are required for end-to-end checks.
- Optional integrations require extra tools: Mike Farah `yq` v4 for YAML note editing and `bwfile`, `nmcli` for Wi-Fi connection, and Python `keyring` plus a usable OS backend for `bwenv store/load/remove` through `bin/bwenv-keyring`.
- Secret-export behavior uses the `BWENV_PREFIX` (default `BWENV_`) and `BW_ENV_SECRETS` environment variables; do not put vault data, sessions, or generated secret output in the repository.
- `bwenv` reads never sync automatically; missing-item errors deliberately recommend `bw sync`, while keyring loads do not contact Bitwarden.
- Run `zsh tests/test-bwenv.zsh` for isolated environment-secret coverage; it puts fake `bw`, `fzf`, and keyring executables first in `PATH` and must never use a real vault.
- Run `zsh tests/test-command-groups.zsh` after changing `bwvault`, `bwitem`, `bwnote`, their help, aliases, loader behavior, or completion registration.
- Run `zsh tests/test-bwssh.zsh` after changing `bwssh`; its fake `bw`, `ssh-add`, `ssh-keygen`, and `fzf` tools must never access a real vault or user key.
- Run `zsh tests/test-bwfile.zsh` after changing `bwfile`; it uses a temporary fake vault and must never access real vault or secret-file data.
- The focused static check is `zsh -n zsh-bitwarden.zsh && zsh -n zsh-bitwarden.plugin.zsh`; run `python3 -m unittest tests/test-bwenv-keyring.py` when changing the helper.
- `bwvault`, `bwitem`, `bwnote`, `bwenv`, `bwfile`, and `bwssh` are the public command groups; legacy short aliases are intentionally removed. Read `README.md` before changing group dispatch or the advanced `bw_tsv`/search pipeline.
- `bwssh` keeps private keys only in Bitwarden and the native agent runtime path. Never add private-key temp files, keyring copies, completion lookups, automatic agent startup, automatic sync, or SSH-config ownership.
- `bwfile` stores YAML metadata in secure-note notes and exact textual payloads in one hidden `content` field. Keep secure same-directory atomic writes, provision-only `--all`, symlink refusal, static completion, no payload cache/output, and no automatic source or local-file deletion.
