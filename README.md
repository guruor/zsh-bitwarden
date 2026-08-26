# zsh-bitwarden

Interactive Zsh workflows on top of the official [Bitwarden CLI](https://github.com/bitwarden/clients/tree/main/apps/cli). The plugin keeps `bw` available for complete CLI access and adds `fzf` selection, structured-note editing, environment-secret loading, and shell completion.

## Install

The plugin works with managers that source `zsh-bitwarden.plugin.zsh`.

```zsh
# Zinit
zinit light guruor/zsh-bitwarden

# Antidote: add to ~/.zsh_plugins.txt, then reload Antidote
guruor/zsh-bitwarden
```

For Oh My Zsh and manual installation, see [INSTALL.md](INSTALL.md). After loading the plugin, verify required and optional integrations:

```zsh
bwdoctor
```

Required commands are `bw`, `jq`, `fzf`, `curl`, and `column`. Clipboard operations use `pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip.exe`, or Oh My Zsh's `clipcopy`.

## Commands

Type a group followed by Tab to explore its commands, or run its `help` command.

```zsh
bwvault help
bwitem help
bwnote help
bwenv help
```

### Vault

```zsh
bwvault unlock
bwvault status
bwvault sync
bwvault lock
```

Reads never synchronize automatically. If a lookup cannot find a recently changed item, run `bwvault sync` and retry.

### Items

```zsh
bwitem password -s github
bwitem username -s github
bwitem credentials -s github
bwitem field -s github -f token
bwitem json -s github

bwitem create login -n mylogin -u user@example.com
bwitem edit password -s mylogin
bwitem edit field -s mylogin -f token
bwitem add field -s mylogin -f token

bwitem generate
bwitem generate alphanumeric
```

Selections use `fzf`. Password and field commands copy to the first available clipboard provider instead of printing values to the terminal.

After a successful create or edit, the plugin confirms that the change was sent to Bitwarden and recommends `bwvault sync` only if a later lookup appears stale.

For advanced jq/TSV selection, use `bwitem search` with the existing search options:

```zsh
bwitem search --simplify -s gmail -c .name -c .username -o .password
```

### Notes

```zsh
bwnote get -s infrastructure
bwnote create -n infrastructure
bwnote edit -s infrastructure
bwnote yaml -s infrastructure
```

`bwnote yaml` requires `yq` and edits a permission-restricted temporary file with `$EDITOR`.

### Environment secrets

Create Bitwarden items with the `BWENV_` prefix, such as `BWENV_OPENAI_API_KEY`. `bwenv` uses the login password when present, otherwise the item note.

```zsh
# Bitwarden -> current shell
bwenv export OPENAI_API_KEY

# Bitwarden -> OS keyring, then keyring -> current shell without unlocking again
bwenv store OPENAI_API_KEY
bwenv load OPENAI_API_KEY

bwenv unset OPENAI_API_KEY
bwenv remove OPENAI_API_KEY
```

Set `BW_ENV_SECRETS="OPENAI_API_KEY GITHUB_TOKEN"` for default names. Without arguments or defaults, `export` and `store` use safe `fzf --multi` selection; only item names and source types reach `fzf`, never decrypted values.

Keyring storage is intentionally limited to explicit environment values. Caching complete Bitwarden items would duplicate structured decrypted vault data and create stale copies. `bwenv store/load/remove` use Python [`keyring`](https://pypi.org/project/keyring/) for macOS Keychain, Linux Secret Service/KWallet, or Windows Credential Manager; see [INSTALL.md](INSTALL.md).

## Security

- No command synchronizes automatically.
- Secrets sent to the keyring helper travel over stdin, not command arguments.
- Completion never queries or unlocks the vault.
- Keyring loading does not contact Bitwarden or expose values in command output.
- Repository tests use fake `bw`, `fzf`, and keyring executables and never access a real vault.

## Acknowledgements

Originally based on [Game4Move78/zsh-bitwarden](https://github.com/Game4Move78/zsh-bitwarden) by Patrick Lenihan.
