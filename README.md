# zsh-bitwarden

Interactive Zsh workflows on top of the official [Bitwarden CLI](https://github.com/bitwarden/clients/tree/main/apps/cli). The plugin keeps `bw` available for complete CLI access and adds `fzf` selection, structured-note editing, environment-secret loading, native SSH-agent key loading, and shell completion.

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
bwssh help
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

### SSH keys

`bwssh` keeps private keys in native Bitwarden SSH-key items and streams them into the operating system's OpenSSH `ssh-agent`. It does not use the Bitwarden Desktop SSH Agent, copy keys into the `bwenv` keyring, start an agent, or write retrieved private keys to files.

```zsh
# Import an existing key once. The source file is not deleted.
bwssh import ~/.ssh/id_ed25519 --name github-personal

# Optional: also write the derived public key to a new dotfiles path.
bwssh import ~/.ssh/work_ed25519 --name github-work \
  --public-key ~/.ssh/public-keys/github-work.pub

# After login/reboot, agent restart, or TTL expiry:
bwssh load

# Then use SSH-backed tools normally.
git pull
git push
ssh production

bwssh list
bwssh status
bwssh unload github-personal
bwssh unload --all
```

With no names, `bwssh load` and `bwssh unload` use safe `fzf --multi` selection. Only item IDs, names, fingerprints, and public-key types reach `fzf`. Set `BW_SSH_TTL=10h` for a default native agent lifetime, or use `bwssh load github-personal --ttl 10h`. With no TTL, `ssh-add` uses its native default behavior.

`bwssh import` takes one input: the private-key path. It runs `ssh-keygen -y` to derive the public key and fingerprint needed by the native Bitwarden SSH-key item. An existing `.pub` file is not required and is not read unless you name it with `--public-key`. That option means "write the derived public key here," not "use this public key as input."

If the `--public-key` path already contains the matching public key, import leaves it unchanged and continues. If it contains a different key, import refuses to overwrite it unless `--force` is supplied. You can therefore import an existing `id_rsa`/`id_rsa.pub` pair with either of these commands:

```zsh
# The existing id_rsa.pub is not needed during import.
bwssh import ~/.ssh/id_rsa --name id_rsa

# Also verify that the existing public file matches the private key.
bwssh import ~/.ssh/id_rsa --name id_rsa --public-key ~/.ssh/id_rsa.pub
```

Bitwarden is the durable encrypted source of truth. The native agent is temporary runtime storage, so loading must be repeated after its identities disappear. Private-key data necessarily passes through the memory of `bw`, `jq`, the plugin pipeline, and `ssh-add`, but it is not intentionally persisted by `bwssh`.

OpenSSH remains responsible for host-to-identity selection. Public keys and SSH configuration can remain in dotfiles:

```sshconfig
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/public-keys/github-personal.pub
    IdentitiesOnly yes

Host production
    HostName prod.example.com
    User ubuntu
    IdentityFile ~/.ssh/public-keys/production.pub
    IdentitiesOnly yes
```

`bwssh` does not parse or modify `~/.ssh/config`. Selected unload uses `ssh-add -d -` with public-key material. If the installed OpenSSH does not support that form, use `bwssh unload --all` or `ssh-add -d /path/to/public-key`.

#### Existing-key migration

1. Keep the existing private key in place during migration, for example `~/.ssh/id_rsa`.
2. Import it with `bwssh import ~/.ssh/id_rsa --name github-personal`. Add `--public-key ~/.ssh/public-keys/github-personal.pub` only when the derived public key should also be written to that path.
3. Load it with `bwssh load github-personal --ttl 10h`.
4. Verify with `ssh-add -l` and the relevant connection, such as `ssh -T git@github.com`.
5. Change `IdentityFile` to the exported public key and set `IdentitiesOnly yes`.
6. Verify normal Git and SSH operations again.
7. Only then manually remove the old private-key file. The plugin never deletes it or rewrites Git history.

Deleting a private key from the current working tree does not remove it from existing Git commits. If it was ever committed, purge it from Git history separately and rotate the exposed key.

## Security

- No command synchronizes automatically.
- Secrets sent to the keyring helper travel over stdin, not command arguments.
- Completion never queries or unlocks the vault.
- Keyring loading does not contact Bitwarden or expose values in command output.
- SSH private keys are streamed to `ssh-add` over stdin and are never stored in the OS keyring or plugin state.
- Repository tests use fake `bw`, `fzf`, OpenSSH, and keyring executables and never access a real vault or user SSH key.

## Acknowledgements

Originally based on [Game4Move78/zsh-bitwarden](https://github.com/Game4Move78/zsh-bitwarden) by Patrick Lenihan.
