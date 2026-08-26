#!/usr/bin/env zsh

setopt errexit nounset pipefail

ROOT="${0:A:h:h}"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export PATH="$ROOT/tests/bin:$PATH"
export BWENV_TEST_LOG="$TEST_TMP/bw.log"
export BWENV_TEST_FZF_LOG="$TEST_TMP/fzf.log"
export BWENV_TEST_KEYRING="$TEST_TMP/keyring"
export BWENV_KEYRING_BIN="$ROOT/tests/bin/bwenv-keyring"
mkdir -p "$BWENV_TEST_KEYRING"
: > "$BWENV_TEST_LOG"
: > "$BWENV_TEST_FZF_LOG"

source "$ROOT/zsh-bitwarden.zsh"

fail() {
    print -u2 "FAIL: $1"
    return 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"
}

output_file="$TEST_TMP/output"
error_file="$TEST_TMP/error"

bwenv export OPENAI_API_KEY > "$output_file" 2> "$error_file"
[[ "$OPENAI_API_KEY" == 'test-openai-value' ]] || fail 'export did not set OPENAI_API_KEY'
[[ "$(<"$output_file")" != *'test-openai-value'* ]] || fail 'export printed a secret value'

bwenv store OPENAI_API_KEY > "$output_file" 2> "$error_file"
bwenv unset OPENAI_API_KEY > "$output_file" 2> "$error_file"
[[ -z "${OPENAI_API_KEY:-}" ]] || fail 'unset left OPENAI_API_KEY in the shell'
: > "$BWENV_TEST_LOG"
bwenv load OPENAI_API_KEY > "$output_file" 2> "$error_file"
[[ "$OPENAI_API_KEY" == 'test-openai-value' ]] || fail 'load did not restore OPENAI_API_KEY'
[[ ! -s "$BWENV_TEST_LOG" ]] || fail 'keyring load contacted Bitwarden'

bwenv remove OPENAI_API_KEY > "$output_file" 2> "$error_file"
if bwenv load OPENAI_API_KEY > "$output_file" 2> "$error_file"; then
    fail 'load succeeded after keyring removal'
fi
assert_contains "$(<"$error_file")" "bwenv store OPENAI_API_KEY"

unset BW_ENV_SECRETS
bwenv export > "$output_file" 2> "$error_file"
[[ "$OPENAI_API_KEY" == 'test-openai-value' ]] || fail 'fzf selection did not export the selected secret'

export BW_ENV_SECRETS='STRUCTURED_SECRET'
bwenv export > "$output_file" 2> "$error_file"
[[ "$STRUCTURED_SECRET" == $'first: one\nsecond: two' ]] || fail 'secure-note value was not exported intact'

if bwenv export MISSING > "$output_file" 2> "$error_file"; then
    fail 'missing Bitwarden item unexpectedly succeeded'
fi
assert_contains "$(<"$error_file")" "Run 'bw sync' and retry"

[[ "$(<"$BWENV_TEST_LOG")" != *'sync'* ]] || fail 'bwenv synced without an explicit user command'
[[ "$(<"$BWENV_TEST_LOG")" != *'test-openai-value'* ]] || fail 'bw invocation log contains a secret value'
[[ "$(<"$BWENV_TEST_FZF_LOG")" != *'test-openai-value'* ]] || fail 'fzf received a secret value'

print 'bwenv tests passed'
