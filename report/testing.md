# Testing

**Scope:** how `src/Pool.sol` is tested, what each test layer can and cannot see, and a mutation experiment that measures how well the suite detects deliberately introduced faults.

**Project context:** Educational project. No mainnet deployment. No independent security review was performed. The results below are evidence about this test suite, these faults and these fuzz seeds. They are not a proof of correctness.

## 1. Test layers

| Layer | Location | What it checks |
|---|---|---|
| Unit tests | `test/Pool.t.sol`, `test/Token.t.sol`, `test/Math.t.sol` | Hand-traced deposits, withdrawals and swaps; revert conditions; boundary values |
| Fuzz tests | `test/Pool.t.sol`, `test/Math.t.sol` | Properties over random inputs: a swap never lowers k, deposit-then-withdraw never profits, withdrawals never dilute remaining providers, swap sequences keep reserves and balances consistent, integer square root is a floor |
| Attack reproductions | `test/FirstDepositorAttack.t.sol`, `test/LockedPoolAttack.t.sol`, `test/MinSharesFix.t.sol`, `test/ReentrancyAttack.t.sol`, `test/RoundingAttack.t.sol` | Each attack against an intentionally vulnerable variant in `src/vulnerable/`, and the matching check that the main pool resists it. See [findings.md](findings.md) |
| Invariant tests | `test/invariant/` | Five rules checked after random sequences of pool actions |

`forge test` runs everything: 55 tests in 10 suites. Foundry counts the invariant contract as one test; it contains five properties.

## 2. Invariant suite

The invariant suite fuzzes sequences of pool actions through a handler (`test/invariant/PoolHandler.sol`) and checks five rules after every sequence (`test/invariant/PoolInvariant.t.sol`).

### Rules

| # | Property | What it asserts |
|---|---|---|
| 1 | `invariant_ReservesMatchBalances` | The pool's recorded reserves equal its actual token balances |
| 2 | `invariant_SharesAccountForTotal` | Every actor's shares, the hostile contract's shares and the 100 permanently locked shares add up to `totalShares` |
| 3 | `invariant_SwapsNeverLowerK` | No executed swap decreased `reserve0 * reserve1` |
| 4 | `invariant_NoDilution` | No deposit or withdrawal decreased reserves per share (checked by cross-multiplication, not division) |
| 5 | `invariant_MinSharesBoundaryHolds` | `minShares = expected + 1` reverts with `SlippageExceeded`; `minShares = expected` succeeds |

### Handler actions

| Action | What it does |
|---|---|
| `swap` | A random actor swaps a bounded amount in a random direction with `minAmountOut = 0`. Skips swaps whose output would be zero. Records whether k decreased |
| `addLiquidity` | A random actor deposits a bounded amount with `minShares = 0`. Skips deposits that would mint zero shares. Checks for dilution |
| `addLiquidityAtBoundary` | Calls `addLiquidity` with `minShares = expected + 1` (must revert with `SlippageExceeded`), then with `minShares = expected` (must succeed) |
| `removeLiquidity` | A random actor burns a bounded number of its own shares. Skips withdrawals that would pay out zero. Checks for dilution |
| `attackerRound` | A hostile contract deposits if it holds no shares, then withdraws. The token0 transfer-out hook re-enters `removeLiquidity` once and swallows the failure of that nested call |

### Setup and configuration

- Three honest actors and one hostile contract, each funded with 1e24 of both tokens.
- The handler seeds the pool in its constructor with a first deposit of 1,000,000 token0 and 1,000,000 token1.
- token0 is a `HookToken`: when the pool transfers it out, the recipient's `onTokenReceived` hook is called. token1 is an ordinary token.
- `foundry.toml` sets `runs = 256`, `depth = 50` (256 sequences of up to 50 calls, 12,800 calls per campaign) and `fail_on_revert = false`.
- Because `fail_on_revert = false`, a reverting handler call does not fail a campaign by itself, so the call table that Foundry prints is worth reading. Clean runs report 0 reverts. The handler also skips inputs that would obviously revert, so the call counts are counts of handler invocations, not of state-changing operations.

### Checking that an action actually runs

When the boundary action was added, a temporary invariant asserted that its counter was still zero. It was expected to fail, and Foundry shrank the failure to a single `addLiquidityAtBoundary` call. That confirmed the action executes. The probe was then removed.

## 3. Mutation experiment

### Method

Each fault is a temporary edit to `src/Pool.sol`. For each one, the unit/fuzz suite (`forge test --no-match-path "test/invariant/*"`) and the invariant suite (`--fuzz-seed 0x1`, `0x2` and `0x3`) were run, and the pool was restored with `git restore src/Pool.sol`. `git diff -- src/Pool.sol` was empty after every experiment.

The unit/fuzz denominators quoted in this section (52 and 54) include two unrelated Foundry template tests that were later removed from the repository. They pass in every run and do not affect any failure count.

### 3.1 Known faults (M1–M6)

| Fault | Edit | Unit/fuzz tests failing | Invariants, first campaign | Invariants, after harness changes |
|---|---|---:|---|---|
| M1 | Delete the `minShares` check in `addLiquidity` | 3 | 0/3 seeds | 3/3 — Rule 5 |
| M2 | Change `<` to `<=` in that check | 2 | 0/3 seeds | 3/3 — Rule 5 |
| M3 | Round withdrawal amounts up instead of down | 3 | 0/3 seeds | 3/3 — Rule 4 |
| M4 | Move the `removeLiquidity` state updates below the token transfers | 2 | 0/3 seeds | 3/3 — Rule 2 |
| M5 | Round swap output up (ceiling division) | 14 | 3/3 — Rule 3 | 3/3 — Rule 3 |
| M6 | Duplicate the `zeroForOne` reserve updates in the other swap branch | 4 | 3/3 — Rules 1 and 3 | 3/3 — Rules 1 and 3 |

M1 and M2 correspond to the evidence in F-02, M4 to F-03 and M5 to F-04 in [findings.md](findings.md).

**How to read this table.** The unit/fuzz suite caught all six faults, but M1–M4 are faults those tests were written to guard against, so that is not independent evidence. The invariant suite initially caught 2 of 6. The four misses had three different causes:

| Cause | Faults | What was missing | What was added |
|---|---|---|---|
| Wrong actions | M1, M2 | The handler always passed `minShares = 0`, so the guard and its exact boundary were never exercised | Rule 5 and the `addLiquidityAtBoundary` action |
| Missing rule | M3 | No invariant expressed that withdrawals must not dilute remaining providers (a fuzz test did) | Rule 4 |
| Missing adversary | M4 | The handler used ordinary tokens, so a hostile callback never happened | `HookToken`, the hostile contract and `attackerRound`; the hostile contract's shares were added to Rule 2 |

Rules 4 and 5 and the hostile actor were written after those faults were seen to escape. The final 6/6 is therefore a tuned result: it shows the suite was improved to catch those faults, not that it catches faults nobody has seen yet. Each fault was detected on all three seeds in at least one measurement round, but not every fault was re-measured after every later harness change.

### 3.2 Held-out faults (H1–H4)

To test the tuning concern, four further faults were chosen by someone who had read the existing tests, and predictions were written down before running them. They were not used to tune the suite beforehand, but they are not a neutral benchmark either: they were selected with knowledge of what the tests contain.

| Fault | Edit | Predicted (unit/fuzz; invariants) | Unit/fuzz failing | Invariants (3 seeds) | Outcome |
|---|---|---|---:|---|---|
| H1 | Fee numerator 997 → 998 (0.3% → 0.2%) | May fail exact-output tests; invariants pass | 2 of 52 | 0/3 failed | Unit/fuzz only. Prediction matched |
| H2 | Remove the `minAmountOut` check in `swap` | Slippage test fails; invariants pass | 1 of 52 | 0/3 failed | Unit/fuzz only. Prediction matched |
| H3 | `shares[msg.sender] = sharesMinted` instead of `+=` | Multi-deposit tests fail; Rule 2 fails | 0 of 52 | 3/3 failed — Rule 2 | Invariants only. Invariant prediction matched, unit/fuzz prediction wrong |
| H4 | `<=` → `<` in the first-deposit minimum-liquidity check | Exact-boundary test fails; invariants may pass | 0 of 52 | 0/3 failed | Escaped both. Unit/fuzz prediction wrong |

**Result: unit/fuzz tests detected 2 of 4, invariants detected 1 of 4, and the union detected 3 of 4. H4 escaped both layers.** This is not a 4/4 result.

What each result shows:

- **H1.** Only 2 of 52 tests noticed. Six hand-traced swap tests kept passing because integer floor division hides a 0.1-point fee change at small trade sizes. Only the two larger trades (5,000 into a reserve of 1,000, and 2,000 into a reserve of 1,000,000) were sensitive enough to expose it. No invariant pins the fee numerator.
- **H2.** The handler always passes `minAmountOut = 0`, so the slippage-rejection branch can never run in the invariant campaign. This is a gap in the generated actions, not bad luck.
- **H3.** The unit/fuzz tests missed it for three specific reasons: `Pool.t.sol` never made two deposits from one address and asserted that address's share balance; `MinSharesFixTest` deposits twice but asserts only reserves and total shares; and the skew-attack demonstration runs against a vulnerable copy, so it adds no check on the main pool's share mapping. Rule 2 (shares add up to the total) caught it immediately.
- **H4.** The handler's first-deposit branch runs once, in its constructor. The 100 locked shares can never be withdrawn, so `totalShares` never returns to zero and no generated sequence can reach that branch again. The escape is structural, not a matter of failing to guess a 100/100 deposit.

**Regression tests added after H4.** Two tests in `test/Pool.t.sol` now pin both sides of the boundary:

- `test_FirstDepositAtMinimumLiquidityBoundaryReverts()`: a first deposit of 100/100 reverts with `ZeroShares` and leaves total shares and reserves at zero.
- `test_FirstDepositJustAboveMinimumLiquidityBoundaryMintsOneShare()`: a first deposit of 101/101 mints exactly 1 share, total shares 101, reserves 101/101.

The rejection test fails against H4 (`next call did not revert as expected`). The success test fails against an over-strict variant (`<= MINIMUM_LIQUIDITY + 1`) with `ZeroShares()`. These tests were added after the measurement, so they are not counted as detection of H4.

### 3.3 Known limits of the invariant harness

- `swap` always passes `minAmountOut = 0`, so slippage rejection on swaps is covered only by unit tests.
- `addLiquidity` passes `minShares = 0`. Only `addLiquidityAtBoundary` exercises the guard.
- The first-deposit branch runs once, in the handler constructor, with 1,000,000 / 1,000,000.
- Hostile-actor coverage is narrow: one recipient-side hook on the token0 transfer-out, re-entering `removeLiquidity` once. It does not cover sender-side hooks during `transferFrom`, read-only reentrancy, or re-entry into `swap` or `addLiquidity`.
- No rule pins a specific fee numerator.
- Reverts are allowed (`fail_on_revert = false`) and the handler skips some inputs, so a zero-revert campaign does not mean every call changed state.
- The campaigns are small: three seeds, 256 sequences of up to 50 calls each. A passing run is not a proof.

### 3.4 What the experiment shows

Unit tests, fuzz tests and invariants caught different classes of fault. An invariant found a share-accounting fault (H3) that 52 unit and fuzz tests missed. Unit tests found two faults (H1, H2) that the invariants cannot see by construction. One fault (H4) escaped both until a targeted boundary test was written. The practical lesson is to ask, for each class of fault, which layer could possibly see it, instead of reading a green run as coverage.

It does not show that the pool is free of other faults, and the 6/6 and 3/4 figures should not be quoted as coverage.

## 4. Reproduce

Unit, fuzz and attack tests, without the invariant suite:

```bash
forge test --no-match-path "test/invariant/*"
```

Invariant suite, one seed at a time (clean first so that Foundry does not replay a cached failure):

```bash
forge clean
forge test --match-path "test/invariant/*" --fuzz-seed 0x1 -vvv
```

Repeat with `0x2` and `0x3`. Look for `[FAIL` lines and `[Sequence] (original: N, shrunk: M)` for the first failure.

Two quick mutation checks (edit `src/Pool.sol`, run, then restore):

| Edit | Command | Expected |
|---|---|---|
| In `addLiquidity`, change `if (initialShares <= MINIMUM_LIQUIDITY)` to `<` | `forge test --match-test test_FirstDepositAtMinimumLiquidityBoundaryReverts -vv` | Fails: `next call did not revert as expected` |
| In `swap`, delete the `if (amountOut < minAmountOut)` block | `forge test --match-test test_SwapRevertsBelowMinAmountOut -vv` | Fails: `next call did not revert as expected` |

Always restore and confirm:

```bash
git restore src/Pool.sol
git diff -- src/Pool.sol   # expected: empty
```
