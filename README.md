# amm-break

A constant-product AMM in Solidity (Foundry), built and then attacked: four attack classes are reproduced against intentionally vulnerable variants and mitigated in the main pool, and the test suite itself is measured with a mutation experiment.

> **Educational project.** No independent security review was performed and nothing is deployed to mainnet. The contracts in `src/vulnerable/` are intentionally broken. Do not deploy anything from this repository.

## What it demonstrates

- A small AMM with LP shares, a 0.3% fee, a permanent minimum-liquidity lock, `minShares` and `minAmountOut` slippage guards, and checks-effects-interactions ordering.
- Four attack classes, each reproduced in a test against a vulnerable variant, with the fix verified in the main pool: first-depositor share inflation, missing minimum-share protection, reentrant withdrawal, and swap output rounded in the trader's favour.
- A layered test suite: unit tests, fuzz tests, and an invariant suite whose handler includes a hostile reentrant contract.
- A mutation experiment that measures what that suite can and cannot detect, including a fault that escaped both the unit/fuzz and invariant layers until a targeted test was added.

## Quick start

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and git. Developed with forge 1.8.6; contracts use `pragma solidity ^0.8.20`.

```bash
git clone --recurse-submodules https://github.com/SV-13/Amm-break.git amm-break
cd amm-break
forge build
forge test
```

If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive` first.

## Repository layout

```
src/
  Pool.sol              The AMM under test
  Token.sol             Minimal mintable ERC-20-style token used by the pool and tests
  Math.sol              Integer square root (floor)
  vulnerable/           Intentionally broken variants used to reproduce attacks
    PoolNoLock.sol        no minimum-liquidity lock
    PoolNoMinShares.sol   lock, but no minShares check
    PoolReentrant.sol     state updated after token transfers
    PoolRoundUp.sol       swap output rounded up
    HookToken.sol         token that calls a hook on the recipient
test/
  Pool.t.sol, Token.t.sol, Math.t.sol     Unit and fuzz tests
  *Attack*.t.sol, MinSharesFix.t.sol      Attack reproductions and fix checks
  invariant/                              Handler and five invariants
report/
  findings.md           Four findings with evidence, severity and residual risk
  testing.md            Test strategy and the mutation experiment
```

## The pool in one screen

| Function | Purpose |
|---|---|
| `addLiquidity(amount0, amount1, minShares)` | Deposit both tokens and mint LP shares; reverts if fewer than `minShares` would be minted |
| `removeLiquidity(sharesToBurn)` | Burn shares and receive a proportional amount of both reserves |
| `swap(tokenIn, amountIn, minAmountOut)` | Swap one token for the other; reverts if the output is zero or below `minAmountOut` |
| `getAmountOut(amountIn, reserveIn, reserveOut)` | Pure quote: `amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997)`, floor division |

Design points:

- Constant product with a 0.3% fee taken from the input (997/1000). Integer division rounds in the pool's favour.
- The first deposit creates `sqrt(amount0 * amount1)` shares. 100 of them (`MINIMUM_LIQUIDITY`) are locked permanently and the depositor receives the rest. Later deposits mint the smaller of the two proportional amounts. Shares are not transferable.
- Reserves are stored in the contract and never read from `balanceOf`.
- State is updated before token transfers in `addLiquidity`, `removeLiquidity` and `swap`.

## Findings

Details, test names and reproduce commands are in [report/findings.md](report/findings.md). Severity is self-assessed (Impact × Likelihood) using definitions given in the report.

| ID | Finding | Severity | Status |
|---|---|---|---|
| F-01 | First-depositor share inflation | High | Partially mitigated (see F-02) |
| F-02 | Missing minimum-share slippage protection | High | Mitigated in the main pool; caller-dependent |
| F-03 | Reentrant liquidity withdrawal | High | Mitigated for the tested callback path |
| F-04 | Swap output rounded up | Medium | Mitigated |

## Testing

[report/testing.md](report/testing.md) describes the unit, fuzz and invariant layers and a mutation experiment against them. Headlines:

- Six known faults were all detected after the invariant harness was improved, but that harness was tuned using those same faults, so the result is not evidence about unseen faults.
- On four further faults chosen after the tests were written (so not a neutral benchmark), unit/fuzz tests detected two, the invariants detected one, and the two layers together detected three. One fault escaped both until a boundary test was added.
- The invariant handler has structural blind spots (for example, it always passes `minAmountOut = 0`), which the report lists.

## Reproduce the demonstrations

| What | Command |
|---|---|
| Everything | `forge test` |
| F-01 attack | `forge test --match-contract FirstDepositorAttackTest -vvv` |
| F-02 attack / fix | `forge test --match-contract LockedPoolAttackTest -vvv` / `forge test --match-contract MinSharesFixTest -vvv` |
| F-03 attack / fix | `forge test --match-contract ReentrancyAttackTest -vvv` / `forge test --match-contract RealPoolReentrancyTest -vvv` |
| F-04 attack and control | `forge test --match-path test/RoundingAttack.t.sol -vvv` |
| Invariant suite | `forge test --match-path "test/invariant/*" -vvv` |

## Scope and limitations

- The reproduced attacks run in local Foundry tests against intentionally vulnerable variants. They are not claims about any deployed protocol, and gas costs and economic viability are not modelled.
- The pool is written against this repository's `Token` type rather than a generic ERC-20 interface, does not use safe-transfer wrappers, and does not handle fee-on-transfer or rebasing tokens.
- `forge build` prints Foundry lint warnings: unchecked ERC-20 return values and events emitted after external calls throughout `src/`, and `reentrancy-no-eth` in `src/vulnerable/PoolReentrant.sol`, which is the intentional fault. The unchecked return values follow from the missing safe-transfer wrappers noted above; the event-ordering warnings are not addressed.
- Not covered: multi-hop routing, price oracles, admin or governance functions, flash loans, transferable LP tokens.
- Reentrancy coverage is limited to a recipient-side token hook during `removeLiquidity`. Sender-side hooks, read-only reentrancy and re-entry into `swap` or `addLiquidity` are not tested.
- Test results are evidence about this suite and these faults, not a proof of correctness.

## License

MIT. See [LICENSE](LICENSE).
