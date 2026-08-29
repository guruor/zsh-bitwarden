# Requirements

Install `zsh`, the Bitwarden CLI (`bw`), `jq`, `fzf`, and `curl`. The plugin also uses `column`, `pgrep`, and `mktemp`, which are normally supplied by the operating system.

Clipboard commands require one of `pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip.exe`, or the Oh My Zsh `clipcopy` function. Run `bwdoctor` after installation to check these dependencies without unlocking the vault.

## Plugin managers

Any Zsh plugin manager can load `zsh-bitwarden.plugin.zsh`. The loader resolves repository-relative files and adds `completions/` to `fpath`.

```zsh
# Zinit
zinit light guruor/zsh-bitwarden

# Antigen
antigen bundle guruor/zsh-bitwarden

# zplug
zplug "guruor/zsh-bitwarden"
```

For Antidote, add `guruor/zsh-bitwarden` to `~/.zsh_plugins.txt`.

## Oh My Zsh

```sh
git clone https://github.com/guruor/zsh-bitwarden \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-bitwarden"
```

Add `zsh-bitwarden` to the plugins in `~/.zshrc`:

```zsh
plugins=(... zsh-bitwarden)
```

## Optional integrations

`bwnote yaml` and all `bwfile` commands require Mike Farah `yq` v4.

`bwssh` requires the operating system's OpenSSH `ssh-add` and `ssh-keygen` commands. A native agent must already be running and reachable through `SSH_AUTH_SOCK`; the plugin does not start or configure one. These commands are available from standard OpenSSH packages on macOS, Linux, and Android/Termux.

`bwenv store`, `bwenv load`, and `bwenv remove` require Python [`keyring`](https://pypi.org/project/keyring/) in the same Python installation used by `bin/bwenv-keyring`:

```sh
python3 -m pip install --user keyring
```

Python keyring uses macOS Keychain, Windows Credential Manager, or an available Linux Secret Service/KWallet backend. Linux may also require distribution packages for Python keyring and a running desktop keyring service.

Reload Zsh and verify the installation:

```zsh
bwdoctor
bwenv doctor
bwfile help
bwssh status
```
