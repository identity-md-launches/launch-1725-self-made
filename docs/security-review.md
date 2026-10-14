# Security review notes

This is an implementation self-review against the supplied v4 and ETH security references, not independent assurance. No third-party audit, formal proof, production deployment, or live transaction was performed.

## Scope and trust

The reviewed production surface is `SelfToken`, `SelfHook`, `Workshop`, and their inlined libraries/interfaces. The factory-supplied PoolManager must be genuine Uniswap v4. The fixed IMD address must keep standard, non-rebasing ERC-20 behavior. Intake controls pricing, job acceptance, and result assertions. Those dependencies and Robinhood Chain remain external trust assumptions; immutability of our contracts does not make them immutable.

## Findings addressed in implementation

| Concern | Resolution and evidence |
| --- | --- |
| Arbitrary callback callers or injected foreign requests | Every enabled v4 callback checks PoolManager. Workshop checks Intake, its own request-index mapping, and Pending state. Unknown/replayed/out-of-order callbacks are tested. |
| NoOp swap theft through `beforeSwapReturnDelta` | The only specified delta is a fee bounded by actual IMD volume (at most the requested 2% input budget). Unspecified before-delta is zero; LP override is zero. The actual AMM still executes. Both currency orders and four swap modes are fuzzed. |
| Partial fills charged on unspent budget | The specified-IMD path uses a reverting same-pool quote. A full rollback preserves the pool state. Fee math is explained below and tested at a tight one-tick price limit and with empty liquidity. |
| Manager cannot transfer a fee before input settlement | A failed `take` rolls back and is replaced by an IMD claim. Tests cover physically insufficient reserves without draining a mock balance, a refusing recipient, permissionless redemption, and a manager with no ETH. |
| Claim theft | Hook claims cannot be transferred or approved through this contract. Its unlock callback burns only its own IMD claims and takes only to immutable Workshop. No recipient argument exists. |
| Wrong or attacker-chosen Workshop address at launch | The hook takes no Workshop argument. Its constructor runs `new Workshop()` and stores the result as the immutable `workshop()`, so the fee recipient is always a fresh, argument-less Workshop with the fixed IMD and Intake constants; nothing in the manifest can point fees elsewhere. Creation is a `CREATE`, not a call, so the constructor still needs no existing code. Tests check the address, the runtime bytes, distinctness per hook, and that a reverted construction leaves no Workshop. |
| Reentrant commissioning or payment failure | OpenZeppelin ReentrancyGuard protects commissions and callbacks. Counters update before external interactions; id registration follows the Intake response. Synchronous callbacks during a request are rejected; protocol delivery is asynchronous. Any failed call, duplicate id, or failed bounty reverts the whole commission. |
| Unlimited approvals | Exact price immediately before request, zero afterward. Mock Intake asserts the allowance it actually sees. Tests include changed prices and rollback. |
| Callback gas grows with results | Request lookup and storage writes are constant-time. Full URI is emitted, its digest stored. URI maximum 2,048 bytes is tested with cold slots below 150k. No delivery calls external contracts. |
| Midnight/cooldown bypass and replay payments | UTC day counter and six-hour rolling cooldown both apply. First-commission sentinel is work count, so timestamp zero cannot bypass it. Result/failure callbacks never pay anyone. Stateful tests cover spending and timing sequences. |
| Mint/owner/proxy escape hatches | Plain OpenZeppelin ERC-20 with constructor-only mint; no admin inheritance in production. Behavioral selector tests and runtime opcode scans reject delegatecall, callcode and selfdestruct. Runtime sizes fit EIP-170. |
| Pool association / predeployment initialization | Full immutable pool key is checked on initialization; required initialization hook returns its exact selector. No key can initialize while hook code is absent. Factory fee collection is tested with zero liquidity change. |
| UI data injection | Event strings go through textContent; link protocols are checked. No event-provided HTML, script, or manifest execution. Reads and wallet writes verify chain 4663. No backend or private-key storage. |

## Arithmetic and partial-fill reasoning

Let A be the gross exact-input IMD budget. The provisional fee is `f = floor(A/50)` and the quote trades `A-f`. If fully filled, the same fee applies. If limited by price or liquidity with pool input R, the fee becomes `min(f, floor(R/49))`. A reduced fee increases the core's available input, but a limit-limited fill still stops at the same limit with the same R. Gross cost is R plus the fee, and `floor((R+floor(R/49))/50) = floor(R/49)`. The input budget is never exceeded.

For net exact-output IMD N, quote gross `N+floor(N/49)`. If output G is limited, fee is `floor(G/50)`, and the core's adjusted target `N+floor(G/50)` remains at least G. Thus it reaches the same limit and charges only the executed output. Without a limit the net output remains exactly N. In unspecified-IMD swaps, the actual pool delta is available directly after the swap.

The quote returns a signed int128 pool delta through a custom-error revert. Only the hook itself can invoke that endpoint. Other errors bubble rather than being misinterpreted as quotes. Fee int128 casts are bounded by at most 1/49 of an int128 pool delta. The int256-min exact-input case avoids negating the original amount before division. Price-plus-bounty affordability uses subtraction to avoid overflow on external uint256 prices. Timestamps are stored as uint48, enough for millions of years.

## Known constraints / release responsibilities

- No permanent state setter or recovery path exists. Removed Intake actions, schema changes, token restrictions, or unavailable delivery can strand funds or requests. This is the requested immutability, not an operator power to fix later.
- The fee is 2% of gross IMD, rounded down. An exact-output buyer pays `pool input + floor(pool input/49)`; the distinction between pool input and gross user debit is intentional and documented.
- IMD may be deferred as claims, so "straight to Workshop" is immediate when transfer succeeds and permissionlessly redeemable otherwise. Workshop cannot spend a claim before redemption.
- A quote simulates some swaps twice and increases gas. Core errors, a token unable to settle the user's trade, insufficient user funds, or insufficient transaction gas can still revert a transaction. No contract can guarantee success for all supplied gas or external-token failures.
- The 2,048-byte URI bound is enforced. Intake must deliver a concise URL/content identifier, not a giant inline payload. Invalid UTF-8 can be logged by Solidity but the website rejects it.
- Pending requests never need clearing to commission again. There is no timeout that spends again or fabricates delivery; history can remain Pending indefinitely. A paid failed job does not refund IMD or reset rate limits.
- The exact constant job texts identify the launch by name/chain, not embedded future addresses. Publication and verification of the launch addresses are the deployer's responsibility so the research templates can discover the intended pool and Workshop.
- The max-four-per-day constraint is also implied by six-hour spacing; the explicit daily state ensures a clear daily limit and view.
- Bounty competition/front-running can cause a caller's transaction to revert after another caller wins. Bounty is not a guaranteed gas reimbursement, and a free/very small Intake price rounds it to zero.
- Static-site operators must publish actual addresses, serve over HTTPS, and use a public CORS-compatible RPC. A compromised frontend/RPC can misrepresent results but has no administrative access to contracts. Website confirmations/overlap handle shallow reorgs, not finality.
- The supplied references' oracle signer, owner setters, ETH conversion, and router allowlists are deliberately absent: this brief requires job callbacks, immutable IMD payment, and unrestricted swaps. No OracleAttestation ABI is substituted for `onResult(bytes32,bytes32,string)`.
- Independent contributor review, source verification, actual factory rehearsal, and monitoring are outstanding release activities. Forge lint was reviewed; timestamp warnings correspond to required cadence, cast bounds are explained above, and commission reentrancy warnings are guarded by ReentrancyGuard. Slither/Mythril and formal verification were not run.
