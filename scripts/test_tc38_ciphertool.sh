#!/usr/bin/env bash
# TC38: ciphertool.sh — encrypt/decrypt round-trip
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CURRENT_TC="TC38"

require_file "${TOOLS_PACK_HOME}/bin/ciphertool.sh"

PLAINTEXT="TestSecret@123"

log_info "T1: ciphertool.sh -encryptText — produce encrypted value"
ENCRYPT_OUT=$(sh "${TOOLS_PACK_HOME}/bin/ciphertool.sh" -encryptText "${PLAINTEXT}" -runtime server 2>&1)
if echo "${ENCRYPT_OUT}" | grep -q "Encrypted value"; then
    log_pass "T1: encryption output contains 'Encrypted value'"
else
    log_fail "T1: encryption failed — no 'Encrypted value' in output"
    print_summary; tc_exit_code
fi

CIPHER=$(echo "${ENCRYPT_OUT}" | grep "Encrypted value" | sed 's/.*Encrypted value : //')

log_info "T2: ciphertext is valid Base64"
if echo "${CIPHER}" | grep -qE '^[A-Za-z0-9+/=]+$'; then
    log_pass "T2: ciphertext is valid Base64"
else
    log_fail "T2: ciphertext is not valid Base64: '${CIPHER}'"
fi

log_info "T3: ciphertool.sh -decryptText — round-trip produces original plaintext"
DECRYPT_OUT=$(sh "${TOOLS_PACK_HOME}/bin/ciphertool.sh" -decryptText "${CIPHER}" -runtime server 2>&1)
DECRYPTED=$(echo "${DECRYPT_OUT}" | grep "Decrypted value" | sed 's/.*Decrypted value : //')
if [[ "${DECRYPTED}" == "${PLAINTEXT}" ]]; then
    log_pass "T3: decrypted value matches original plaintext"
else
    log_fail "T3: expected '${PLAINTEXT}', got '${DECRYPTED}'"
fi

print_summary; tc_exit_code
