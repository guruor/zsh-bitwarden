#!/usr/bin/env zsh

setopt errexit nounset pipefail

ROOT="${0:A:h:h}"
TEST_TMP="${$(mktemp -d):A}"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export PATH="$ROOT/tests/bin:$PATH"
export HOME="$TEST_TMP/home"
export BWFILE_TEST_MODE=1
export BWFILE_TEST_LOG="$TEST_TMP/bw.log"
export BWFILE_TEST_STATE="$TEST_TMP/vault.json"
mkdir -p "$HOME"
: > "$BWFILE_TEST_LOG"
print -r -- '[]' > "$BWFILE_TEST_STATE"

source "$ROOT/zsh-bitwarden.zsh"

fail() { print -u2 "FAIL: $1"; return 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "output unexpectedly contained: $2"; }
assert_mode() { [[ "$(_bwfile_file_mode "$1")" == "$2" ]] || fail "wrong mode for $1: $(_bwfile_file_mode "$1")"; }

output="$TEST_TMP/output"
error="$TEST_TMP/error"

bwfile help > "$output"
assert_contains "$(<"$output")" 'bwfile <command>'
if bwfile unknown > "$output" 2> "$error"; then fail 'unknown command succeeded'; fi
assert_contains "$(<"$error")" 'Unknown bwfile command'

bwfile list > "$output" 2> "$error"
assert_contains "$(<"$output")" 'NAME'

mkdir -p "$HOME/.aws" "$HOME/.config/app"
aws="$HOME/.aws/credentials"
secret='BWFILE_TEST_SECRET_9f81'
print -rn -- $'[default]\nkey='"$secret"$'\n\n[backup]\nkey=two\n' > "$aws"
chmod 600 "$aws"
bwfile save "$aws" --name 'aws-credentials' --description 'AWS credentials; $(touch never)' > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Saved BWFILE_AWS_CREDENTIALS'
assert_not_contains "$(<"$output")$(<"$error")" "$secret"
assert_not_contains "$(<"$BWFILE_TEST_LOG")" "$secret"
[[ ! -e never ]] || fail 'description executed shell content'
jq -e --arg secret "$secret" '
  length == 1 and .[0].type == 2 and .[0].name == "BWFILE_AWS_CREDENTIALS"
  and (. [0].notes | contains("path: ~/.aws/credentials"))
  and (. [0].notes | contains("version: 2"))
  and ([.[0].fields[] | select(.name == "content_0001" and .type == 1 and (.value | contains($secret)))] | length == 1)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'saved item representation is incorrect'

temp="$BWFILE_TEST_STATE.tmp"
jq 'map(if .name == "BWFILE_AWS_CREDENTIALS" then
  .fields += [{name:"owner",value:"platform",type:0},{name:"environment",value:"local",type:1}]
  else . end)' "$BWFILE_TEST_STATE" > "$temp" && mv "$temp" "$BWFILE_TEST_STATE"

if bwfile save "$aws" --name AWS_CREDENTIALS > "$output" 2> "$error"; then fail 'duplicate save succeeded'; fi
assert_contains "$(<"$error")" 'already exists'
print -rn -- 'replacement without newline' > "$aws"
bwfile save "$aws" --name AWS_CREDENTIALS --force > "$output" 2> "$error"
[[ "$(jq -r '.[0].fields[] | select(.name == "content_0001") | .value' "$BWFILE_TEST_STATE")" == 'replacement without newline' ]] || fail 'forced update did not preserve new content'
[[ "$(jq -r '.[0].id' "$BWFILE_TEST_STATE")" != null ]] || fail 'update lost item identity'
jq -e '
  [.[] | select(.name == "BWFILE_AWS_CREDENTIALS")][0].fields
  | ([.[] | select(.name == "owner" and .value == "platform" and .type == 0)] | length == 1)
    and ([.[] | select(.name == "environment" and .value == "local" and .type == 1)] | length == 1)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'version 2 update did not preserve unrelated custom fields'

empty="$HOME/.config/app/empty"
: > "$empty"
chmod 400 "$empty"
bwfile save "$empty" > "$output" 2> "$error"
assert_contains "$(<"$output")" 'BWFILE_EMPTY'
assert_contains "$(<"$output")" 'Mode: 0400'
jq -e '[.[] | select(.name == "BWFILE_EMPTY")][0].fields == [{name:"content_0001",value:"",type:1}]' "$BWFILE_TEST_STATE" >/dev/null || fail 'empty content was not represented by one empty chunk'

binary="$TEST_TMP/binary"
printf 'text\0binary' > "$binary"
if bwfile save "$binary" > "$output" 2> "$error"; then fail 'binary save succeeded'; fi
assert_contains "$(<"$error")" 'textual files'
if bwfile save "$empty" --name PUBLIC_MODE --mode 0644 > "$output" 2> "$error"; then fail 'other-readable mode succeeded'; fi
assert_contains "$(<"$error")" 'Unsafe mode'
assert_contains "$(<"$error")" "--mode 0600"
if bwfile save "$empty" --name NEWLINE_DESCRIPTION --description $'line one\nline two' > "$output" 2> "$error"; then fail 'control-character description succeeded'; fi
assert_contains "$(<"$error")" 'unsupported metadata characters'
if bwfile save "$HOME/.config" > "$output" 2> "$error"; then fail 'directory save succeeded'; fi
source_link="$HOME/.config/app/credentials-link"
ln -s "$aws" "$source_link"
bwfile save "$source_link" --name SYMLINK_SOURCE > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Path: ~/.config/app/credentials-link'
jq -e '
  [.[] | select(.name == "BWFILE_SYMLINK_SOURCE")][0]
  | (.notes | contains("path: ~/.config/app/credentials-link"))
    and ([.fields[] | select(.name == "content_0001" and .value == "replacement without newline")] | length == 1)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'symlink source path or target content was not preserved'
bwfile remove SYMLINK_SOURCE --force > "$output" 2> "$error"
[[ -L "$source_link" ]] || fail 'removing symlink-source item changed the local symlink'
rm "$source_link"
odd_source="$HOME/.config/app/secret file; \$(touch never-source).yaml"
print -r -- 'opaque: value' > "$odd_source"
chmod 640 "$odd_source"
bwfile save "$odd_source" > "$output" 2> "$error"
assert_contains "$(<"$output")" 'BWFILE_SECRET_FILE_TOUCH_NEVER_SOURCE_YAML'
[[ ! -e never-source ]] || fail 'shell-sensitive source path was evaluated'

large="$HOME/.config/app/large-unicode-secret.asc"
large_expected="$TEST_TMP/large-expected"
printf '%*s' 7001 '' | tr ' ' x > "$large"
print -rn -- $'é秘密\nwithout trailing newline' >> "$large"
cp "$large" "$large_expected"
chmod 600 "$large"
bwfile save "$large" --name LARGE_UNICODE > "$output" 2> "$error"
jq -e '
  [.[] | select(.name == "BWFILE_LARGE_UNICODE")][0]
  | (.notes | contains("version: 2"))
    and ([.fields[] | select(.name | test("^content_[0-9]{4}$"))] | length == 3)
    and ([.fields[] | select(.name | test("^content_[0-9]{4}$")) | (.value | utf8bytelength <= 3500)] | all)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'large payload was not split into bounded chunks'
rm "$large"
bwfile load LARGE_UNICODE > "$output" 2> "$error"
cmp -s "$large" "$large_expected" || fail 'chunked Unicode payload did not round-trip exactly'
assert_not_contains "$(<"$output")$(<"$error")$(<"$BWFILE_TEST_LOG")" '秘密'

multibyte="$HOME/.config/app/multibyte-secret"
printf '🔐%.0s' {1..1000} > "$multibyte"
chmod 600 "$multibyte"
bwfile save "$multibyte" --name MULTIBYTE_BOUNDARY > "$output" 2> "$error"
jq -e '
  [.[] | select(.name == "BWFILE_MULTIBYTE_BOUNDARY")][0].fields
  | length == 2 and all(.[]; (.value | utf8bytelength) <= 3500)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'multibyte payload was not split by UTF-8 byte length'

failed_source="$HOME/.config/app/create-failure"
print -r -- 'not logged' > "$failed_source"
chmod 600 "$failed_source"
export BWFILE_FAIL_COMMAND=create
if bwfile save "$failed_source" > "$output" 2> "$error"; then fail 'create failure succeeded'; fi
assert_contains "$(<"$error")" 'Unable to create'
assert_not_contains "$(<"$output")$(<"$error")$(<"$BWFILE_TEST_LOG")" 'not logged'
unset BWFILE_FAIL_COMMAND

rm -f "$aws"
bwfile load AWS_CREDENTIALS > "$output" 2> "$error"
[[ "$(<"$aws")" == 'replacement without newline' ]] || fail 'load did not restore exact content'
assert_mode "$aws" 0600
assert_not_contains "$(<"$output")$(<"$error")" 'replacement without newline'
bwfile load AWS_CREDENTIALS > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Up to date'
chmod 400 "$aws"
bwfile load AWS_CREDENTIALS > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Corrected mode'
assert_mode "$aws" 0600
print -rn -- 'local change' > "$aws"
if bwfile load AWS_CREDENTIALS > "$output" 2> "$error"; then fail 'differing destination was overwritten'; fi
[[ "$(<"$aws")" == 'local change' ]] || fail 'differing destination changed'
bwfile load AWS_CREDENTIALS --force > "$output" 2> "$error"
[[ "$(<"$aws")" == 'replacement without newline' ]] || fail 'forced load failed'

rm -f "$aws"
ln -s "$TEST_TMP/symlink-target" "$aws"
if bwfile load AWS_CREDENTIALS --force > "$output" 2> "$error"; then fail 'symlink destination load succeeded'; fi
assert_contains "$(<"$error")" 'symlink'
rm -f "$aws"
mv "$HOME/.aws" "$HOME/.aws-real"
ln -s "$HOME/.aws-real" "$HOME/.aws"
if bwfile load AWS_CREDENTIALS > "$output" 2> "$error"; then fail 'symlink parent load succeeded'; fi
assert_contains "$(<"$error")" 'symlink component'
rm "$HOME/.aws"
mv "$HOME/.aws-real" "$HOME/.aws"

recovery="$HOME/.config/app/recovery.pem"
print -r -- '-----BEGIN PRIVATE RECOVERY-----' > "$recovery"
chmod 600 "$recovery"
bwfile save "$recovery" --name RECOVERY_CERT --lifecycle recovery > "$output" 2> "$error"
rm -f "$recovery" "$aws"
bwfile load --all > "$output" 2> "$error"
[[ -e "$aws" ]] || fail 'bulk provision did not restore provision file'
[[ ! -e "$recovery" ]] || fail 'bulk --all restored recovery file'
assert_contains "$(<"$output")" 'Summary:'
bwfile load --lifecycle recovery > "$output" 2> "$error"
[[ -e "$recovery" ]] || fail 'explicit recovery load failed'

bwfile list --search AWS > "$output" 2> "$error"
assert_contains "$(<"$output")" 'AWS_CREDENTIALS'
assert_not_contains "$(<"$output")" 'RECOVERY_CERT'
assert_not_contains "$(<"$output")" "$secret"
bwfile show AWS_CREDENTIALS > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Local state: present and matches'
assert_not_contains "$(<"$output")" 'replacement without newline'
bwfile status > "$output" 2> "$error"
assert_contains "$(<"$output")" 'AWS_CREDENTIALS: present and matches'

# Version 1 single-field items remain readable.
temp="$BWFILE_TEST_STATE.tmp"
jq '. + [{id:"legacy-v1",type:2,name:"BWFILE_LEGACY_V1",notes:"version: 1\npath: ~/.config/app/legacy-v1\nmode: \"0600\"\nlifecycle: recovery",fields:[{name:"content",type:1,value:"legacy payload"},{name:"content_backup",type:1,value:"stale payload"},{name:"owner",type:0,value:"local"}]}]' "$BWFILE_TEST_STATE" > "$temp" && mv "$temp" "$BWFILE_TEST_STATE"
bwfile load LEGACY_V1 > "$output" 2> "$error"
[[ "$(<"$HOME/.config/app/legacy-v1")" == 'legacy payload' ]] || fail 'version 1 item did not load'
print -rn -- 'migrated payload' > "$HOME/.config/app/legacy-v1"
bwfile save "$HOME/.config/app/legacy-v1" --name LEGACY_V1 --force > "$output" 2> "$error"
jq -e '
  [.[] | select(.name == "BWFILE_LEGACY_V1")][0]
  | (.notes | contains("version: 2"))
    and ([.fields[] | select(.name == "content")] | length == 0)
    and ([.fields[] | select(.name == "content_backup")] | length == 0)
    and ([.fields[] | select(.name == "content_0001" and .value == "migrated payload")] | length == 1)
    and ([.fields[] | select(.name == "owner" and .value == "local")] | length == 1)
' "$BWFILE_TEST_STATE" >/dev/null || fail 'version 1 item was not cleanly migrated to version 2'

# Invalid versions and unsafe modes are reported, never interpreted.
temp="$BWFILE_TEST_STATE.tmp"
jq '. + [
  {id:"future",type:2,name:"BWFILE_FUTURE",notes:"version: 3\npath: ~/.future\nmode: \"0600\"\nlifecycle: provision",fields:[{name:"content",type:1,value:"hidden-future"}]},
  {id:"unsafe",type:2,name:"BWFILE_UNSAFE",notes:"version: 1\npath: ~/.unsafe\nmode: \"0622\"\nlifecycle: provision",fields:[{name:"content",type:1,value:"hidden-unsafe"}]},
  {id:"missing-content",type:2,name:"BWFILE_MISSING_CONTENT",notes:"version: 1\npath: ~/.missing-content\nmode: \"0600\"\nlifecycle: provision",fields:[]},
  {id:"missing-chunk",type:2,name:"BWFILE_MISSING_CHUNK",notes:"version: 2\npath: ~/.missing-chunk\nmode: \"0600\"\nlifecycle: recovery",fields:[{name:"content_0002",type:1,value:"gap"}]},
  {id:"duplicate-chunk",type:2,name:"BWFILE_DUPLICATE_CHUNK",notes:"version: 2\npath: ~/.duplicate-chunk\nmode: \"0600\"\nlifecycle: recovery",fields:[{name:"content_0001",type:1,value:"one"},{name:"content_0001",type:1,value:"two"}]},
  {id:"malformed-chunk",type:2,name:"BWFILE_MALFORMED_CHUNK",notes:"version: 2\npath: ~/.malformed-chunk\nmode: \"0600\"\nlifecycle: recovery",fields:[{name:"content_0001",type:1,value:"one"},{name:"content_backup",type:1,value:"stale"}]},
  {id:"oversized-chunk",type:2,name:"BWFILE_OVERSIZED_CHUNK",notes:"version: 2\npath: ~/.oversized-chunk\nmode: \"0600\"\nlifecycle: recovery",fields:[{name:"content_0001",type:1,value:("x" * 3501)}]},
  {id:"ordinary",type:2,name:"ORDINARY_NOTE",notes:"not bwfile",fields:[{name:"content",type:1,value:"unrelated"}]}
]' "$BWFILE_TEST_STATE" > "$temp" && mv "$temp" "$BWFILE_TEST_STATE"
if bwfile status > "$output" 2> "$error"; then fail 'invalid metadata status succeeded'; fi
assert_contains "$(<"$output")" 'unsupported metadata version'
assert_contains "$(<"$output")" 'unsafe mode'
assert_not_contains "$(<"$output")$(<"$error")" 'hidden-future'
if bwfile load MISSING_CONTENT > "$output" 2> "$error"; then fail 'missing content field loaded'; fi
assert_contains "$(<"$error")" 'Unable to retrieve content'
if bwfile load MISSING_CHUNK > "$output" 2> "$error"; then fail 'non-contiguous content chunks loaded'; fi
assert_contains "$(<"$error")" 'Unable to retrieve content'
if bwfile load DUPLICATE_CHUNK > "$output" 2> "$error"; then fail 'duplicate content chunks loaded'; fi
if bwfile load MALFORMED_CHUNK > "$output" 2> "$error"; then fail 'malformed reserved content field was ignored'; fi
if bwfile load OVERSIZED_CHUNK > "$output" 2> "$error"; then fail 'oversized content chunk loaded'; fi

# Metadata containing shell syntax remains inert and invalid relative paths cannot escape.
temp="$BWFILE_TEST_STATE.tmp"
jq '. + [{id:"inject",type:2,name:"BWFILE_INJECT",notes:"version: 1\npath: $(touch /tmp/bwfile-pwned)\nmode: \"0600\"\nlifecycle: provision\ndescription: \"`touch /tmp/bwfile-pwned-2`; * | > < &\"",fields:[{name:"content",type:1,value:"hidden-inject"}]}]' "$BWFILE_TEST_STATE" > "$temp" && mv "$temp" "$BWFILE_TEST_STATE"
if bwfile load INJECT > "$output" 2> "$error"; then fail 'relative injection path loaded'; fi
[[ ! -e /tmp/bwfile-pwned && ! -e /tmp/bwfile-pwned-2 ]] || fail 'metadata executed shell content'
assert_not_contains "$(<"$output")$(<"$error")" 'hidden-inject'

local_copy="$recovery"
if bwfile remove RECOVERY_CERT > "$output" 2> "$error"; then fail 'non-interactive remove skipped confirmation'; fi
assert_contains "$(<"$error")" 'Confirmation requires a terminal'
bwfile remove RECOVERY_CERT --force > "$output" 2> "$error"
[[ -e "$local_copy" ]] || fail 'remove deleted the local file'
assert_contains "$(<"$output")" 'local file was not deleted'
if bwfile remove MISSING --force > "$output" 2> "$error"; then fail 'missing remove succeeded'; fi
export BWFILE_FAIL_COMMAND=delete
if bwfile remove AWS_CREDENTIALS --force > "$output" 2> "$error"; then fail 'delete failure succeeded'; fi
unset BWFILE_FAIL_COMMAND

completion="$(<"$ROOT/completions/_bwfile")"
assert_not_contains "$completion" 'bw list'
assert_not_contains "$completion" 'content field'
[[ "$(<"$BWFILE_TEST_LOG")" != *sync* ]] || fail 'bwfile synchronized automatically'
print 'bwfile tests passed'
