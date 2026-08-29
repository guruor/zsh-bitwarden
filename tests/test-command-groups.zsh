#!/usr/bin/env zsh

setopt errexit nounset pipefail

ROOT="${0:A:h:h}"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
CALL_LOG="$TEST_TMP/calls"
: > "$CALL_LOG"
export PATH="$ROOT/tests/bin:$PATH"

autoload -Uz compinit
compinit -D
source "$ROOT/zsh-bitwarden.plugin.zsh"

fail() {
  print -u2 "FAIL: $1"
  return 1
}

record() {
  print -r -- "$*" >> "$CALL_LOG"
}

_bw_mutation_notice() { :; }
bw_unlock() { record bw_unlock "$@"; }
bw_lock() { record bw_lock "$@"; }
bw_serve() { record bw_serve "$@"; }
bw_status() { record bw_status "$@"; }
bw_sync() { record bw_sync "$@"; }
bw_tsv() { record bw_tsv "$@"; }
bw_user_pass() { record bw_user_pass "$@"; }
bw_field() { record bw_field "$@"; }
bw_generate() { record bw_generate "$@"; }
bw_create_login() { record bw_create_login "$@"; }
bw_json_edit() { record bw_json_edit "$@"; }
bw_edit_name() { record bw_edit_name "$@"; }
bw_edit_username() { record bw_edit_username "$@"; }
bw_edit_password() { record bw_edit_password "$@"; }
bw_edit_field() { record bw_edit_field "$@"; }
bw_add_field() { record bw_add_field "$@"; }
bw_create_note() { record bw_create_note "$@"; }
bw_edit_note() { record bw_edit_note "$@"; }
bw_notes_field_edit_as_yaml() { record bw_notes_field_edit_as_yaml "$@"; }
_bwssh_import() { record _bwssh_import "$@"; }
_bwssh_load() { record _bwssh_load "$@"; }
_bwssh_unload() { record _bwssh_unload "$@"; }
_bwssh_list() { record _bwssh_list "$@"; }
_bwssh_status() { record _bwssh_status "$@"; }
_bwfile_save() { record _bwfile_save "$@"; }
_bwfile_load() { record _bwfile_load "$@"; }
_bwfile_list() { record _bwfile_list "$@"; }
_bwfile_show() { record _bwfile_show "$@"; }
_bwfile_status() { record _bwfile_status "$@"; }
_bwfile_remove() { record _bwfile_remove "$@"; }

bwvault unlock
bwvault status
bwvault sync
bwitem password github
bwitem username github
bwitem credentials github
bwitem field --field token github
bwitem json github
bwitem generate alphanumeric
bwitem create login --name example
bwitem edit password github
bwitem add field --field token
bwnote get infrastructure
bwnote create --name infrastructure
bwnote edit infrastructure
bwnote yaml infrastructure
bwssh import '/key path' --name example
bwssh load example --ttl 10h
bwssh unload example
bwssh list --search example
bwssh status
bwfile save '/secret path' --name example
bwfile load example
bwfile list --search example
bwfile show example
bwfile status
bwfile remove example --force

calls="$(<"$CALL_LOG")"
for expected in \
  'bw_unlock' \
  'bw_status' \
  'bw_sync' \
  'bw_tsv -l -c .name -c .login.username -O .login.password github' \
  'bw_tsv -l -c .name -o .login.username github' \
  'bw_user_pass github' \
  'bw_field --field token github' \
  'bw_generate -uln --length 21' \
  'bw_create_login --name example' \
  'bw_edit_password github' \
  'bw_add_field --field token' \
  'bw_tsv -n -c .name -o .notes infrastructure' \
  'bw_create_note --name infrastructure' \
  'bw_edit_note infrastructure' \
  'bw_notes_field_edit_as_yaml infrastructure'; do
  [[ "$calls" == *"$expected"* ]] || fail "missing dispatch: $expected"
done

for expected in \
  '_bwfile_save /secret path --name example' \
  '_bwfile_load example' \
  '_bwfile_list --search example' \
  '_bwfile_show example' \
  '_bwfile_status' \
  '_bwfile_remove example --force'; do
  [[ "$calls" == *"$expected"* ]] || fail "missing bwfile dispatch: $expected"
done

for expected in \
  '_bwssh_import /key path --name example' \
  '_bwssh_load example --ttl 10h' \
  '_bwssh_unload example' \
  '_bwssh_list --search example' \
  '_bwssh_status'; do
  [[ "$calls" == *"$expected"* ]] || fail "missing bwssh dispatch: $expected"
done

for old_alias in bwul bwst bwpw bwus bwno bwg bwlc bwnc bwexp bwsync; do
  (( ! $+aliases[$old_alias] )) || fail "legacy alias remains: $old_alias"
done

[[ "${_comps[bwenv]}" == _bwenv ]] || fail 'bwenv completion is not registered'
[[ "${_comps[bwfile]}" == _bwfile ]] || fail 'bwfile completion is not registered'
[[ "${_comps[bwvault]}" == _bwvault ]] || fail 'bwvault completion is not registered'
[[ "${_comps[bwitem]}" == _bwitem ]] || fail 'bwitem completion is not registered'
[[ "${_comps[bwnote]}" == _bwnote ]] || fail 'bwnote completion is not registered'
[[ "${_comps[bwssh]}" == _bwssh ]] || fail 'bwssh completion is not registered'

ROOT="$ROOT" zsh -f -c '
  source "$ROOT/zsh-bitwarden.plugin.zsh"
  autoload -Uz compinit
  compinit -D
  [[ ${_comps[bwenv]} == _bwenv && ${_comps[bwfile]} == _bwfile && ${_comps[bwvault]} == _bwvault &&
     ${_comps[bwitem]} == _bwitem && ${_comps[bwnote]} == _bwnote &&
     ${_comps[bwssh]} == _bwssh ]]
' || fail 'completion failed when the plugin loaded before compinit'

# Exercise completion branches without invoking Bitwarden or an interactive widget.
typeset -ga completion_specs
_arguments() { completion_specs=("$@"); }
_values() { completion_specs=("$@"); }
_describe() { completion_specs=("$@"); }
_bwfile_completion_under_test() { source "$ROOT/completions/_bwfile"; }

words=(bwfile save)
CURRENT=3
completion_specs=()
_bwfile_completion_under_test
save_specs="${(j: :)completion_specs}"
for expected in '--name' '--lifecycle' '--mode' '--description' '--force' '--update' '_files'; do
  [[ "$save_specs" == *"$expected"* ]] || fail "bwfile save completion is missing: $expected"
done
[[ "$save_specs" != *'(- 1 *)--force'* ]] || fail 'bwfile save --force incorrectly excludes the file argument'

words=(bwfile load)
completion_specs=()
_bwfile_completion_under_test
load_specs="${(j: :)completion_specs}"
for expected in '--force' '--all' '--lifecycle' 'logical name'; do
  [[ "$load_specs" == *"$expected"* ]] || fail "bwfile load completion is missing: $expected"
done

words=(bwfile list)
completion_specs=()
_bwfile_completion_under_test
[[ "${(j: :)completion_specs}" == *'--search'* ]] || fail 'bwfile list completion is missing --search'

words=(bwfile remove)
completion_specs=()
_bwfile_completion_under_test
[[ "${(j: :)completion_specs}" == *'--force'* ]] || fail 'bwfile remove completion is missing --force'

words=(bwfile help)
completion_specs=()
_bwfile_completion_under_test
help_specs="${(j: :)completion_specs}"
for expected in save load list show status remove; do
  [[ "$help_specs" == *"$expected"* ]] || fail "bwfile help completion is missing: $expected"
done

temp_secret="$(print -rn -- 'temporary-test-value' | bw_init_file)"
EDITOR=false
if bw_edit_file "$temp_secret"; then
  fail 'failed editor unexpectedly succeeded'
fi
[[ ! -e "$temp_secret" ]] || fail 'failed editor left a decrypted temporary file behind'

bwdoctor > "$TEST_TMP/doctor"
[[ "$(<"$TEST_TMP/doctor")" == *'ok: bw (test-bw 1.0)'* ]] || fail 'bwdoctor did not validate the Bitwarden CLI'
[[ "$(<"$TEST_TMP/doctor")" == *'ok: fzf (test-fzf 1.0)'* ]] || fail 'bwdoctor did not validate fzf'

print 'command group tests passed'
