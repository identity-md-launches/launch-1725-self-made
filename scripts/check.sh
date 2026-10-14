#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
forge build
FOUNDRY_FUZZ_SEED=0x99916e5cf1208eaffc733ca5fdb62b7fe1882a6253cfc072044785ff4763acb9 forge test
forge fmt --check
node --test web/test/*.test.mjs
