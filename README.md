# Self Made ($SELF)

Self Made is a fixed-supply token whose SELF/IMD trading fees fund an immutable Workshop. A public caller triggers a commission when its balance and clock permit; the Workshop pays Identity.md Intake, rotates through four fixed jobs, and rewards the caller. Delivered work appears in a static, wallet-optional gallery.

## Run and check

Requirements: Foundry with Solidity **0.8.26** installed; Node 18+ for the website tests. Solidity dependencies are vendored as ordinary source files in `lib/`. No package installation, submodules, network, environment configuration, FFI, or filesystem cheatcode permissions are needed for the default checks.

```sh
forge build
forge test
forge fmt --check
node --test web/test/*.test.mjs
# or: ./scripts/check.sh
```

The supplied fuzz seed is pinned in `foundry.toml`. Stateful tests use 64 sequences of 32 calls. The default suite excludes `test/fork/` so an offline verifier can run it. Fork integration is a separate, explicitly network-dependent check:

```sh
./scripts/check-fork.sh
```

The fork uses Robinhood Chain **4663**, public RPC `https://rpc.mainnet.chain.robinhood.com`, and its **latest available state** (the public endpoint prunes historical state). The first integration run passed at block **88,278,305**; its observation is retained as evidence. It uses the real IMD and Intake contracts, a locally deployed Uniswap PoolManager, and locally deployed launch contracts. It actually calls `requestWithFailure` on the fork. It never broadcasts, spends live funds, or submits an off-chain job. See [fork evidence](docs/fork-evidence.json) and [verification](docs/verification.md).

## Contracts and parameters

| Contract | Constructor | Purpose |
| --- | --- | --- |
| `SelfToken` | none | ERC-20 `Self Made` / `SELF`, 18 decimals, exactly 1,000,000,000 tokens (`10^27` units), minted once to its deployer, the launch factory. |
| `Workshop` | none | Fixed protocol addresses and exact constant job bodies; permissionless commissions and authenticated delivery records. **Not deployed by the launch**: `SelfHook` creates it. |
| `SelfHook` | `IPoolManager manager`, `address token` | The launch supplies only the documented placeholders `$poolManager` and `$token`. The constructor runs `new Workshop()` and exposes the result as the immutable `workshop()`; all hook fees go to that address. Neither argument is an owner. |

There is no pre-deployed Workshop. Because `Workshop` takes no constructor arguments (IMD and Intake are constants), the hook deploys its own copy with a plain `CREATE` from its constructor. The Workshop address is therefore `keccak256(rlp([hookAddress, 1]))`, the hook's first creation, and is read after launch with `SelfHook.workshop()`. The hook's init code embeds the Workshop's creation code; its runtime does not.

There is **no owner, admin, pause, blacklist, mint-after-deployment, withdrawal, upgrade, mutable fee, or setter** in these contracts. Constructors make no external calls and require no external code to exist: creating the Workshop is a contract creation, not a call to an existing contract, so the launch's empty-chain constructor check still passes. IMD and Intake are deliberately constants because this brief requires immutable contracts:

- IMD: `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals).
- Intake v2: `0xa43e6f75ee006411f79ac1c84120606c2330de82`.
- Action: right-padded `bytes32("job.open@job-1")`, not its hash.
- Pool: SELF/IMD, LP fee **12,500 = 1.25%**, tick spacing **60**. The additional hook fee is **2% of gross IMD**.

The factory handles the supply split: 88% pool, 10% launch Merkle distributor, 2% launch payer/treasury. No token allocation goes to Workshop or the hook. The factory also derives the opening square-root price from its 2,500 IMD opening market-cap policy and the actual currency ordering. The `1:1` price in local tests is a test fixture, not a launch-price instruction.

## Fee accounting

The hook takes IMD only, never SELF or ETH, and never converts the fee. Define **gross IMD** as the total IMD debited from a buyer, or the pool's IMD output before the hook fee on a sale. The fee is `floor(gross / 50)`; sub-50-unit fees round to zero. LP fees remain separate and the hook never overrides them.

| Swap | IMD role | Fee path |
| --- | --- | --- |
| Buy SELF, exact IMD input | specified input | Reserve `floor(input / 50)` in `beforeSwap`. |
| Sell SELF, exact IMD output | specified output | Gross up net output with `floor(net / 49)` in `beforeSwap`. |
| Buy SELF, exact SELF output | unspecified input | Charge `floor(pool IMD input / 49)` in `afterSwap`. |
| Sell SELF, exact SELF input | unspecified output | Charge `floor(pool IMD output / 50)` in `afterSwap`. |

For specified IMD, `quoteIMD` executes a same-pool swap inside a self-call that **always reverts** with the actual IMD delta. The revert rolls back pool state, accounting, and logs. Uniswap skips a hook's own swap callbacks, so the quote does not recurse. This quote lets a price-limited partial fill pay for executed volume instead of the whole requested amount. The real swap then runs normally with its caller's direction and price limit. Quote failures preserve the core's error. This costs an extra pool simulation for two of the four swap modes; it does not replace the AMM or consume the entire input as a custom swap.

Fees are taken directly from PoolManager to Workshop. Because the router settles its input after callbacks, PoolManager can temporarily lack physical IMD. A failed direct transfer creates an **IMD ERC-6909 claim owned by SelfHook** instead of reverting the trade. Anyone can call `redeemFees()` after settlement; redemption can only send IMD to the fixed Workshop. It redeems up to the manager's available balance, leaving any remainder as claims. This narrowly defined fallback preserves swap liveness; pending claims are not yet spendable Workshop balance. A failed redemption leaves claims intact. Workshop and Intake readiness never block a swap. Core liquidity, price-limit, caller settlement, token behavior, and gas constraints still apply.

Permissions are exactly `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`: low 14 address bits **`0x20cc` (8396)**. Initialization accepts only the immutable SELF/IMD pool and checks PoolManager as caller. It also prevents initializing the predicted hook address before its code exists. All enabled callbacks and `unlockCallback` authenticate PoolManager. There are no liquidity callbacks, so adding, removing, and zero-delta fee collection remain untouched.

## Workshop rules and delivery

`commission()` is open to everyone and has no body or recipient input. It reads `Intake.priceOf(ACTION, IMD)` on every call and requires enough IMD for that price plus `floor(price / 50)` caller bounty. It approves **exactly** the price, calls `requestWithFailure` with `onResult` and `onFailure`, clears any residual allowance, records the request, and pays the bounty. An external failure reverts the entire commission, including approvals, rotation, clock, daily count, and payment. Reentrancy is guarded.

The first funded commission is immediately eligible. Later commissions must be at least **6 hours** apart and there can be no more than **4 per UTC day** (`timestamp / 86400`). The rolling cooldown crosses midnight. The daily cap is explicit, even though six-hour spacing already implies it for monotonic timestamps. The fourth daily commission makes a fifth revert with `DailyLimit`. Failed or unanswered jobs still count; no refunds or early retries are promised. Pending work never blocks the next scheduled commission.

The exact four UTF-8 JSON bodies from the assignment are constants in `src/WorkOrders.sol`. They rotate `0 → 1 → 2 → 3 → 0`: meme, vertical video, public report, security review. Each is below Intake's 16,384-byte body limit. There is no caller-supplied job text.

Only Intake can call `onResult` or `onFailure`, only for a request this Workshop made, and only once. Out-of-order delivery is supported. A foreign payer cannot inject a result by naming Workshop as their callback. Failure status must be 1 or 2; counts and signature are informational and never authorize spending. These are job callbacks, not the distinct oracle-attestation ABI.

`works(i)` returns `(requestId, resultHash, uriHash, commissionedAt, completedAt, templateIndex, state)`, where state is `Pending=0`, `Built=1`, or `Failed=2`. The result hash and **URI digest** are stored; the full URI is published in `Built(requestId, templateIndex, resultHash, uri)`. To guarantee the callback gas budget, URI length is capped at **2,048 UTF-8 bytes**; longer delivery attempts revert. This is a chosen transport bound, not a change to the job bodies. A maximum-length cold-storage delivery is tested below 150k gas. Failure emits `Failed(requestId, status, reason)`. URI contents and result hashes are Intake's assertions, not independent content verification.

Views include `nextTemplate()`, `lastCommissionAt()`, `commissionsToday()`, `canCommission()`, `works(i)`, `workCount()`, `nextCommissionAt()`, and `templateBody(index)`. `canCommission()` returns false when price/balance reads fail. A quote can become stale before mining; callers must handle a reverted transaction or another caller taking the bounty first.

## Launch preparation

This repository does not deploy or broadcast, and deliberately has no `launch.json`. The later manifest/deployer supplies actual addresses and the factory's policy. The manifest's `SelfHook` entry needs only `constructorArgs: ["$poolManager", "$token"]`; it lists no Workshop, because none exists before the hook is deployed and the hook creates it. Deploy `SelfToken` first, then mine and deploy `SelfHook` with the token address and the supplied PoolManager. Initialize and seed the pool through the launch factory in its deployment transaction.

`script/MineSelfHook.s.sol:MineSelfHook` provides a pure, bounded CREATE2 miner. Its `run(factory, poolManager, token, start, attempts)` returns the salt, predicted address, and init-code hash. It uses the **factory address**, not a wallet or the script address. Maximum search batch is 1,000,000 candidates. Continue another range if no salt is found. A test mines, actually deploys, and checks the resulting constructor arguments and bits. The production factory's actual CREATE2 salt convention must be used; if it transforms salts, use its own miner with the same `0x20cc` mask.

After launch, the deployer verifies the three sources and their constructor arguments (`Workshop` has none and is verified at the address `SelfHook.workshop()` reports), publishes the hook and Workshop addresses and the deployment block, confirms the correct pool key and hook bits, and configures the static gallery from the hook as described below. No contract configuration transactions are possible or required. Independent adversarial review remains a release responsibility; passing these tests is not an audit.

## Gallery and logo

```sh
python3 -m http.server 8080 --directory web
```

Open `http://localhost:8080`. The site ships in an honest **prelaunch** state with no made-up contract address or sample results. After deployment, give the configuration script the **hook** address; it reads `workshop()` from the hook over JSON-RPC and writes that address into `web/config.json`. The Workshop address is never typed by hand, so the gallery can only point at the Workshop the hook actually pays:

```sh
node scripts/configure-gallery.mjs \
  --hook ACTUAL_DEPLOYED_SELFHOOK_ADDRESS \
  --deployment-block ACTUAL_DEPLOYMENT_BLOCK \
  [--rpc-url https://a-public-cors-enabled-robinhood-rpc]
```

The script refuses to write when the RPC is not chain 4663, the hook or the reported Workshop has no code, or `workshop()` does not return a nonzero address. It uses the RPC in `web/config.json` unless `--rpc-url` is given, in which case it also records that endpoint. It is tested against a stub RPC by `node --test web/test/*.test.mjs`.

Publish the `web/` directory on any static host. It requires no build step, CDN, package manager, backend, indexer, or wallet to read. Configure a public CORS-enabled Robinhood RPC in `web/config.json`; never publish an API secret. The gallery pages `Built` logs from the deployment block, newest first, refreshes every 15 seconds, and re-reads a 20-block overlap for shallow reorgs with two confirmation blocks. Displayed data is provisional, not a finality guarantee. Network errors retain loaded items and disable commissioning until fresh data is available. IMD balance, price, bounty, timing and readiness are read at the same block. The countdown uses chain time and reports when funding is insufficient.

Each item links to its delivery URI. Direct image/video URLs get previews; report or manifest/page URLs get a link. Only HTTPS and converted IPFS/Arweave links are opened, and event text is inserted as text, never HTML. The site does not fetch or interpret arbitrary manifests. Unsafe URIs fall back to the delivery transaction. Content may change, disappear, or be inaccurate. Clicking the optional commission button asks the user's own wallet to send one transaction on chain 4663; the site never requests token approval or a key.

The original lime-on-black robot-hand logo is `web/assets/self-logo.svg`, with included 64, 256, and 512 px PNG exports. SVG is the editable source; the site uses it directly. All site assets are local.

## Operational responsibilities and immutable dependencies

Any public keeper or user must submit `commission()` transactions, pay ETH gas, and decide whether the IMD bounty covers their costs. Smart contracts cannot wake themselves up. Anyone may redeem deferred fees; no privileged keeper exists. The network supplies Intake processing and asynchronous delivery. The static host/RPC operator provides gallery availability; they have no contract powers.

The launch contracts cannot migrate if Intake, its action schema, IMD transfer behavior, or the launch chain changes. Intake may change its live price, so a commission can consume a higher price when enough funds exist; this is intentional, with no owner-set price ceiling. If Intake permanently stops serving this action or IMD cannot be transferred, Workshop funds have no rescue path. Unrelated tokens or forced native currency sent to Workshop are likewise not withdrawable. No protocol addresses, private keys, external owners, or placeholder wallets need to be supplied by the requester for this implementation.

See [security review notes](docs/security-review.md), [dependency pins](docs/dependencies.json), and [third-party notices](NOTICE.md).
