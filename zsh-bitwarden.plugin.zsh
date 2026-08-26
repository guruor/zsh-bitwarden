# According to the standard:
# https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

typeset -gU fpath
fpath=("${0:h}/completions" $fpath)

source "${0:h}/zsh-bitwarden.zsh"

if (( $+functions[compdef] )); then
  autoload -Uz _bwenv _bwvault _bwitem _bwnote
  compdef _bwenv bwenv
  compdef _bwvault bwvault
  compdef _bwitem bwitem
  compdef _bwnote bwnote
fi
