# Third-party notices

Self Made source code and original website/logo assets are MIT licensed; see LICENSE.

Vendored dependencies are ordinary files, with upstream licenses preserved. Exact revisions are recorded in `docs/dependencies.json`:

- Uniswap v4-core, Uniswap Labs: `lib/v4-core/licenses/` and individual SPDX declarations. Portions are BUSL-1.1; interfaces/libraries have their stated licenses. The production hook imports interfaces and libraries. The PoolManager implementation is used for local/fork testing. This project's MIT license does not relicense v4-core.
- OpenZeppelin Contracts v5.1.0: MIT, `lib/openzeppelin-contracts/LICENSE`.
- Foundry forge-std v1.9.7: Apache-2.0 OR MIT, `lib/forge-std/LICENSE-APACHE` and `LICENSE-MIT`.
- Solmate: AGPL-3.0-only and individual SPDX declarations, `lib/solmate/LICENSE`. Its `Owned` contract is a dependency of the test PoolManager, not the launch token, hook, or Workshop.

The task's pinned ETH/security/oracle references were consulted as background; their owner/setter suggestions were not applied where they conflict with this immutable launch. No oracle-attestation implementation is included because this is a job.open consumer.
