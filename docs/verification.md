# Verification record

Checked locally on 2026-10-14 with Foundry 1.8.5 and the project-pinned Solidity 0.8.26 compiler. These are contributor check results, not independent review or production attestations.

| Check | Result |
| --- | --- |
| `forge build` / `forge build --offline` | Passed; all imported Solidity dependencies are local ordinary files. |
| `forge test --offline -vv` | **64 tests passed**, zero failed, zero skipped, across eight suites. |
| Required fuzz seed | `0x99916e5cf1208eaffc733ca5fdb62b7fe1882a6253cfc072044785ff4763acb9`, pinned and also supplied for the final run. |
| Fuzz tests | 256 runs each: four swap modes in both currency orders with partial/full fills, token transfers, and dynamic-price/bounty conservation. |
| Stateful invariants | 64 sequences × 32 calls each; zero handler reverts. Hook conservation/fees and Workshop timing, rotation, and spending invariants passed. |
| `FOUNDRY_PROFILE=fork forge test -vv` | **5 tests passed**, zero failed/skipped; real Robinhood IMD and Intake v2, freshly deployed local PoolManager and launch contracts. |
| `forge fmt --check` | Passed. |
| `node --test web/test/*.test.mjs` | **8 tests passed**; ABI decoding, URI filtering, precision, countdown, reorg replacement, pagination, block-consistent reads, errors and configuration. |
| Browser QA | Chromium headless: 1440 px desktop and 390 px mobile; no JavaScript errors or horizontal overflow. Mocked-RPC browser flow verified real DOM rendering, newest-first items, unsafe-URI fallback, wallet transaction construction, stale-state disablement, and retained items during RPC failure. |
| Callback gas | Maximum 2,048-byte URI, nonzero hash, cold account/storage: **138,256 gas**, below 150,000. Fork callback also succeeded with a 149,999-gas call budget. |
| Runtime escape hatches | SelfToken, SelfHook and Workshop passed opcode scans for DELEGATECALL, CALLCODE and SELFDESTRUCT; admin selector probes failed as intended. |
| Runtime size | SelfToken 1,722 bytes; SelfHook 6,232 bytes; Workshop 6,460 bytes. All below 24,576-byte EIP-170 limit. |

The five fork tests cover all four swap directions/modes paying IMD, trading fees funding a real `requestWithFailure`, dynamic `priceOf`, exact affordability, bounty, the six-hour interval, UTC cap/reset, four bodies reaching Intake, and callback access/gas. Authentication acceptance is simulated by impersonating Intake locally; the tests do not impersonate a production wallet onchain or exercise the off-chain swarm's completion service. Intake accepting request bytes is not proof that the job was completed.

The initial four-test fork run passed at explicitly selected RPC block 88,278,305. A later historical rerun failed because the public endpoint reported that historical state was unavailable. The maintained fork suite therefore selects latest available state and logs its EVM block number; the final five-test run reported **26,190,127**. On this Orbit chain, execution block numbering and RPC block identifiers need not be interchangeable. The initial RPC header observation is retained in `fork-evidence.json`; the live test has no dependency on that historical block. Archive availability is not hidden by silently skipping tests.

Browser tooling and screenshots were local QA only. The delivered site and its Node tests require no Playwright, Python package, downloaded browser, or network-installed dependency. The original SVG and PNG exports are included as ordinary deliverable files.

Not performed: Slither, Mythril, formal verification, an independent adversarial audit, actual launch-factory deployment, explorer verification, or off-chain job delivery. See `security-review.md` for release responsibilities and limitations.
