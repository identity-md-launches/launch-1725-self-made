#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FOUNDRY_PROFILE=fork FOUNDRY_FUZZ_SEED=0x99916e5cf1208eaffc733ca5fdb62b7fe1882a6253cfc072044785ff4763acb9 forge test -vv
