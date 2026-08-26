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

for old_alias in bwul bwst bwpw bwus bwno bwg bwlc bwnc bwexp bwsync; do
  (( ! $+aliases[$old_alias] )) || fail "legacy alias remains: $old_alias"
done

[[ "${_comps[bwenv]}" == _bwenv ]] || fail 'bwenv completion is not registered'
[[ "${_comps[bwvault]}" == _bwvault ]] || fail 'bwvault completion is not registered'
[[ "${_comps[bwitem]}" == _bwitem ]] || fail 'bwitem completion is not registered'
[[ "${_comps[bwnote]}" == _bwnote ]] || fail 'bwnote completion is not registered'

ROOT="$ROOT" zsh -f -c '
  source "$ROOT/zsh-bitwarden.plugin.zsh"
  autoload -Uz compinit
  compinit -D
  [[ ${_comps[bwenv]} == _bwenv && ${_comps[bwvault]} == _bwvault &&
     ${_comps[bwitem]} == _bwitem && ${_comps[bwnote]} == _bwnote ]]
' || fail 'completion failed when the plugin loaded before compinit'

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
