#!/usr/bin/env zsh

setopt errexit nounset pipefail

ROOT="${0:A:h:h}"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
export PATH="$ROOT/tests/bin:$PATH"
export BWSSH_TEST_MODE=1
export BWSSH_TEST_LOG="$TEST_TMP/bw.log"
export BWSSH_TEST_FZF_LOG="$TEST_TMP/fzf.log"
export BWSSH_TEST_SSH_ADD_LOG="$TEST_TMP/ssh-add.log"
export BWSSH_TEST_SSH_KEYGEN_LOG="$TEST_TMP/ssh-keygen.log"
export BWSSH_TEST_AGENT_STATE="$TEST_TMP/agent-state"
export SSH_AUTH_SOCK="$TEST_TMP/agent.sock"
: > "$BWSSH_TEST_LOG"
: > "$BWSSH_TEST_FZF_LOG"
: > "$BWSSH_TEST_SSH_ADD_LOG"
: > "$BWSSH_TEST_SSH_KEYGEN_LOG"
: > "$BWSSH_TEST_AGENT_STATE"

source "$ROOT/zsh-bitwarden.zsh"

fail() {
    print -u2 "FAIL: $1"
    return 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"
}

output="$TEST_TMP/output"
error="$TEST_TMP/error"

bwssh help > "$output"
assert_contains "$(<"$output")" 'bwssh <command>'

unset BW_SESSION
: > "$BWSSH_TEST_LOG"
bwssh status > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Vault: unlocked'
assert_contains "$(<"$output")" 'Stored keys: unavailable without an existing BW_SESSION'
[[ "$(<"$BWSSH_TEST_LOG")" != *unlock* ]] || fail 'status unlocked the vault'
export BWSSH_VAULT_STATUS=locked
bwssh status > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Vault: locked'
unset BWSSH_VAULT_STATUS

export BW_SESSION=test-session
bwssh list > "$output" 2> "$error"
assert_contains "$(<"$output")" 'github-personal'
assert_contains "$(<"$output")" 'SHA256:GITHUB'
[[ "$(<"$output")$(<"$error")" != *TEST_PRIVATE* ]] || fail 'list emitted private key material'

unset SSH_AUTH_SOCK
if bwssh load github-personal > "$output" 2> "$error"; then
    fail 'load succeeded without an SSH agent'
fi
assert_contains "$(<"$error")" 'SSH_AUTH_SOCK is empty'
export SSH_AUTH_SOCK="$TEST_TMP/agent.sock"

: > "$BWSSH_TEST_SSH_ADD_LOG"
if ! bwssh load github-personal --ttl 10h > "$output" 2> "$error"; then
    fail "load failed: $(<"$error")"
fi
assert_contains "$(<"$output")" 'Loaded: github-personal'
assert_contains "$(<"$BWSSH_TEST_SSH_ADD_LOG")" '-t 10h -'
[[ "$(<"$BWSSH_TEST_SSH_ADD_LOG")$(<"$output")$(<"$error")" != *TEST_PRIVATE* ]] || fail 'load disclosed private key material'

: > "$BWSSH_TEST_AGENT_STATE"
: > "$BWSSH_TEST_SSH_ADD_LOG"
BW_SSH_TTL=45m bwssh load github-personal > "$output" 2> "$error"
assert_contains "$(<"$BWSSH_TEST_SSH_ADD_LOG")" '-t 45m -'

: > "$BWSSH_TEST_SSH_ADD_LOG"
bwssh load github-personal > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Already loaded: github-personal'
ssh_add_calls=("${(f)$(<"$BWSSH_TEST_SSH_ADD_LOG")}")
(( ${ssh_add_calls[(I)-]} == 0 )) || fail 'already-loaded key was sent to ssh-add again'

: > "$BWSSH_TEST_AGENT_STATE"
: > "$BWSSH_TEST_FZF_LOG"
export BWSSH_FZF_ALL=1
if ! bwssh load > "$output" 2> "$error"; then
    fail "multi-load failed: $(<"$error")"
fi
unset BWSSH_FZF_ALL
assert_contains "$(<"$output")" 'Loaded: github-personal'
[[ "$(<"$output")" == *'Loaded: work key; $(touch never)'* ]] || fail "second selected key was not loaded: $(<"$output")"
[[ ! -e never ]] || fail 'shell-sensitive item name was evaluated'
[[ "$(<"$BWSSH_TEST_FZF_LOG")" != *TEST_PRIVATE* ]] || fail 'fzf received private key material'
bwssh list > "$output" 2> "$error"
assert_contains "$(<"$output")" 'yes  github-personal'
assert_contains "$(<"$output")" 'yes  work key; $(touch never)'
bwssh status > "$output" 2> "$error"
assert_contains "$(<"$output")" 'loaded  github-personal  SHA256:GITHUB'
assert_contains "$(<"$output")" 'loaded  work key; $(touch never)  SHA256:WORK'

private_dir="$TEST_TMP/key dir; safe"
mkdir -p "$private_dir"
private_path="$private_dir/id import"
public_path="$private_dir/public key.pub"
print -rn -- 'TEST_PRIVATE_IMPORT' > "$private_path"
if ! bwssh import "$private_path" --name 'import key; $(touch never-import)' --public-key "$public_path" > "$output" 2> "$error"; then
    fail "import failed: $(<"$error")"
fi
assert_contains "$(<"$output")" 'Imported: import key; $(touch never-import)  SHA256:IMPORT'
[[ "$(<"$public_path")" == 'ssh-ed25519 AAAATESTIMPORT import@test' ]] || fail 'public key output is incorrect'
[[ -e "$private_path" ]] || fail 'import deleted the source private key'
[[ ! -e never-import ]] || fail 'shell-sensitive import name was evaluated'
[[ "$(<"$BWSSH_TEST_LOG")$(<"$BWSSH_TEST_SSH_KEYGEN_LOG")$(<"$output")$(<"$error")" != *TEST_PRIVATE_IMPORT* ]] || fail 'import disclosed private key material'

if ! bwssh import "$private_path" --name existing-public --public-key "$public_path" > "$output" 2> "$error"; then
    fail "import with an existing matching public key failed: $(<"$error")"
fi
assert_contains "$(<"$output")" 'Public key already exists and matches:'

print -r -- 'ssh-ed25519 AAAADIFFERENT other@test' > "$public_path"
if bwssh import "$private_path" --name mismatched-public --public-key "$public_path" > "$output" 2> "$error"; then
    fail 'import overwrote a mismatched public key without --force'
fi
assert_contains "$(<"$error")" 'does not match the private key'
bwssh import "$private_path" --name replaced-public --public-key "$public_path" --force > "$output" 2> "$error"
[[ "$(<"$public_path")" == 'ssh-ed25519 AAAATESTIMPORT import@test' ]] || fail 'forced public key output was not replaced'

export BWSSH_DUPLICATE_IMPORT=true
if bwssh import "$private_path" --name duplicate > "$output" 2> "$error"; then
    fail 'duplicate fingerprint import succeeded without --force'
fi
assert_contains "$(<"$error")" 'already exists'
bwssh import "$private_path" --name duplicate --force > "$output" 2> "$error"
unset BWSSH_DUPLICATE_IMPORT

export BWSSH_FAIL_COMMAND=create
if bwssh import "$private_path" --name create-failure > "$output" 2> "$error"; then
    fail 'import succeeded when bw create failed'
fi
assert_contains "$(<"$error")" 'Bitwarden test create failure.'
unset BWSSH_FAIL_COMMAND

export BWSSH_FAIL_COMMAND=create BWSSH_CREATE_PRIVATE_ERROR=1
if bwssh import "$private_path" --name redacted-failure > "$output" 2> "$error"; then
    fail 'import succeeded when bw create returned a private error'
fi
assert_contains "$(<"$error")" 'details were redacted'
[[ "$(<"$error")" != *TEST_PRIVATE_IMPORT* ]] || fail 'create error disclosed private key material'
unset BWSSH_FAIL_COMMAND BWSSH_CREATE_PRIVATE_ERROR

invalid="$TEST_TMP/invalid key"
print -r -- 'INVALID' > "$invalid"
if bwssh import "$invalid" > "$output" 2> "$error"; then
    fail 'invalid private key import succeeded'
fi
assert_contains "$(<"$error")" 'not a supported private SSH key'

print -r -- 'SHA256:GITHUB' > "$BWSSH_TEST_AGENT_STATE"
bwssh unload github-personal > "$output" 2> "$error"
assert_contains "$(<"$output")" 'Unloaded: github-personal'
[[ ! -s "$BWSSH_TEST_AGENT_STATE" ]] || fail 'selected unload left the identity loaded'
print -r -- 'SHA256:GITHUB' > "$BWSSH_TEST_AGENT_STATE"
bwssh unload --all > "$output" 2> "$error"
[[ ! -s "$BWSSH_TEST_AGENT_STATE" ]] || fail 'unload --all left identities loaded'

unset BW_SESSION
export BWSSH_FAIL_COMMAND=unlock
if bwssh list > "$output" 2> "$error"; then
    fail 'list succeeded with an unavailable vault'
fi
unset BWSSH_FAIL_COMMAND
export BW_SESSION=test-session

export BWSSH_FAIL_COMMAND=get
if bwssh load github-personal > "$output" 2> "$error"; then
    fail 'load succeeded when bw get failed'
fi
unset BWSSH_FAIL_COMMAND

export BWSSH_FAIL_SSH_KEYGEN=1
if bwssh import "$private_path" --name failed > "$output" 2> "$error"; then
    fail 'import succeeded when ssh-keygen failed'
fi
unset BWSSH_FAIL_SSH_KEYGEN

: > "$BWSSH_TEST_AGENT_STATE"
export BWSSH_FAIL_SSH_ADD=1
if bwssh load github-personal > "$output" 2> "$error"; then
    fail 'load succeeded when ssh-add failed'
fi
unset BWSSH_FAIL_SSH_ADD

if (jq() { return 1; }; bwssh list > "$output" 2> "$error"); then
    fail 'list succeeded when jq failed'
fi

[[ "$(<"$BWSSH_TEST_LOG")" != *sync* ]] || fail 'bwssh synchronized without an explicit command'
print 'bwssh tests passed'
