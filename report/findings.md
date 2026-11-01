# Findings

**Scope:** `src/Pool.sol` (constant-product pool with a 0.3% fee) and intentionally vulnerable variants in `src/vulnerable/`.

**Project context:** Educational project. No mainnet deployment. No independent security review was performed.

## Severity methodology

Severity is self-assessed using Impact × Likelihood.

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| High | Medium | High | Critical |
| Medium | Low | Medium | High |
| Low | Low | Low | Medium |

Definitions:

- **Low impact:** Limited, recoverable loss with little effect on users.
- **Medium impact:** Material loss affecting a portion of user funds or functionality.
- **High impact:** Major loss of user funds or complete loss of access to deposited assets.
- **Low likelihood:** Requires unusual conditions or unsupported token behaviour.
- **Medium likelihood:** Requires a specific but realistic integration or transaction sequence.
- **High likelihood:** Can be triggered through ordinary supported operations without unusual preconditions.

The ratings below are project assessments, not formal audit ratings.

## Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| F-01 | First-depositor share inflation | High (self-assessed) | Partially mitigated (see F-02) |
| F-02 | Missing minimum-share slippage protection | High (self-assessed) | Mitigated in main implementation; caller-dependent |
| F-03 | Reentrant liquidity withdrawal | High (self-assessed) | Mitigated in main implementation for the tested callback path |
| F-04 | Swap output rounded up | Medium (self-assessed) | Mitigated in main implementation |

---

## F-01 — First-depositor share inflation

| Field | Value |
|---|---|
| Severity | High (self-assessed) |
| Status | Partially mitigated (see F-02) |
| Impact | High — in the demonstrated attack, the victim loses 3,332 of 10,000 token0 (33.32%) and 8,332 of 10,000 token1 (83.32%) |
| Likelihood | Medium — requires control of initial pool creation and a subsequent victim deposit |
| Vulnerable implementation | `src/vulnerable/PoolNoLock.sol` |
| Additional comparison | Locked pool without `minShares` protection |
| Mitigation | `MINIMUM_LIQUIDITY` and first-deposit checks in `Pool.addLiquidity()` |
| Demonstration | `test_FirstDepositorAttackStealsFromVictim()` in `FirstDepositorAttackTest` |
| Additional comparison tests | `test_SkewAttackProfitsWhenDepositsHaveNoMinimum()` and `test_TinyInitialDepositBlockedByLiquidityLock()` in `LockedPoolAttackTest` |
| Reproduce | `forge test --match-contract FirstDepositorAttackTest -vvv` and `forge test --match-contract LockedPoolAttackTest -vvv` |

### What happens

The attacker initializes the vulnerable pool with 4 token0 and 4 token1, receiving all four initial LP shares. The attacker then deposits 30,000 token0 and only 1 token1, skewing the reserve ratio before the victim deposits 10,000 of each asset. The victim receives one share while the attacker owns five of the six shares and withdraws first. This is the AMM analogue of an ERC-4626 first-depositor share-inflation attack, but here the manipulation uses an unbalanced deposit rather than a token donation: `Pool.sol` tracks reserves in storage and does not derive them from token `balanceOf`.

### Demonstration trace — vulnerable pool without the lock

| Step | Action | Shares after action (attacker / victim / total) | Reserves after action (token0 / token1) | Withdrawal |
|---|---|---|---|---|
| 1 | Attacker deposits 4 / 4 | 4 / 0 / 4 | 4 / 4 | — |
| 2 | Attacker deposits 30,000 / 1 | 5 / 0 / 5 | 30,004 / 5 | — |
| 3 | Victim deposits 10,000 / 10,000 | 5 / 1 / 6 | 40,004 / 10,005 | — |
| 4 | Attacker burns 5 shares | 0 / 1 / 1 | 6,668 / 1,668 | 33,336 / 8,337 |
| 5 | Victim burns 1 share | 0 / 0 / 0 | 0 / 0 | 6,668 / 1,668 |

The test asserts that the attacker's net gains are 3,332 token0 and 8,332 token1. The victim's net losses are exactly the same quantities.

### What the lock does and doesn't stop

The main pool's 100-share minimum-liquidity lock prevents the original 4/4 initialization because its geometric-mean share amount is only four. However, the lock alone does not eliminate the skew attack when minimum-share protection is absent.

The locked-pool comparison was reproduced by:

- `test_SkewAttackProfitsWhenDepositsHaveNoMinimum()` — demonstrates the skew attack against `PoolNoMinShares`, which retains the 100-share lock but has no `minShares` check.
- `test_TinyInitialDepositBlockedByLiquidityLock()` — verifies that the minimum-liquidity lock rejects the tiny initial deposit.

| Measurement | No lock (`PoolNoLock`) | Lock, no `minShares` |
|---|---:|---:|
| Attacker opening deposit | 4 / 4 | 1,000 / 1,000 (4 / 4 reverts) |
| Attacker skew deposit | 30,000 / 1 | 30,000 / 1,000 |
| Victim shares minted | 1 | 645 |
| Victim net (token0 / token1) | −3,332 / −8,332 | −2 / −7,074 |
| Attacker net (token0 / token1) | +3,332 / +8,332 | −1,549 / +6,620 |

At the pool's opening 1:1 reference price, the locked-pool attacker is still nominally net-positive: −1,549 + 6,620 = +5,071. The victim loses 7,074 token1, or 70.74% of the 10,000 token1 deposited, and 2 token0.

The lock blocks the tiny-supply setup but does not replace per-deposit minimum-share protection.

### Root cause and mitigation

In `PoolNoLock`, `MINIMUM_LIQUIDITY` is zero, so the first provider receives the entire initial share supply.

The main `Pool.addLiquidity()` implementation sets `MINIMUM_LIQUIDITY` to 100, rejects an initial share amount less than or equal to that lock, subtracts the lock from the provider's minted shares, and includes the locked amount in `totalShares`.

This prevents the demonstrated tiny first deposit, but meaningful `minShares` protection is still required to protect later deposits against an unacceptable share calculation.

### Regression coverage

- `test_TinyFirstDepositReverts()`
- `test_FirstDepositMintsSharesAndLocksMinimum()`
- `test_FirstDepositAtMinimumLiquidityBoundaryReverts()`
- `test_FirstDepositJustAboveMinimumLiquidityBoundaryMintsOneShare()`
- `test_SkewAttackRevertsWhenMinSharesIsSet()`

---

## F-02 — Missing minimum-share slippage protection

| Field | Value |
|---|---|
| Severity | High (self-assessed) |
| Status | Mitigated in main implementation; caller-dependent |
| Impact | High — the victim can lose 7,074 of 10,000 token1 (70.74%) and 2 token0 in the demonstrated locked-pool attack |
| Likelihood | Medium — requires reserve manipulation and an absent, zero or insufficient minimum-share threshold |
| Vulnerable implementation | `src/vulnerable/PoolNoMinShares.sol` |
| Mitigation | `minShares` parameter and `sharesMinted < minShares` check in `Pool.addLiquidity()` |
| Demonstration (attack) | `test_SkewAttackProfitsWhenDepositsHaveNoMinimum()` in `LockedPoolAttackTest` |
| Fix verification | `test_SkewAttackRevertsWhenMinSharesIsSet()`, `test_HonestDepositPassesWithMinShares()`, `test_MinSharesBoundary()` |
| Reproduce (attack) | `forge test --match-contract LockedPoolAttackTest -vvv` |
| Reproduce (fix) | `forge test --match-contract MinSharesFixTest -vvv` |

### What happens

The attacker initializes the locked pool with 1,000 token0 and 1,000 token1, then adds 30,000 token0 and 1,000 token1 to skew its reserves. The resulting pool has reserves of 31,000 token0 and 2,000 token1, with 2,000 total shares. When the victim deposits 10,000 of each token, the pool calculates only 645 shares because the token0 reserve ratio is the limiting side. Without a minimum-share check, the victim can accept this unexpectedly poor allocation.

### What the fix does

The vulnerable `PoolNoMinShares.addLiquidity()` accepts only `amount0` and `amount1`. It calculates shares but has no caller-supplied minimum-share requirement.

The corrected `Pool.addLiquidity()` accepts a third parameter:

`addLiquidity(amount0, amount1, minShares)`

After calculating `sharesMinted`, it checks:

```solidity
if (sharesMinted < minShares) {
    revert SlippageExceeded(sharesMinted, minShares);
}
```

The check occurs before share accounting, reserve updates and token transfers.

In `test_SkewAttackRevertsWhenMinSharesIsSet()`, the victim requires at least 9,900 shares. The pool calculates 645, resulting in:

`SlippageExceeded(645, 9900)`

The first value, 645, is the number of shares actually calculated by the pool. The second value, 9,900, is the minimum number requested by the victim.

The test also verifies that a rejected deposit leaves wallet balances, reserves, total shares, victim shares and pool token balances unchanged.

The protection does not automatically reject honest deposits. `test_HonestDepositPassesWithMinShares()` verifies that a balanced deposit mints 10,000 shares and succeeds with a minimum requirement of 9,900.

### Evidence the tests can fail

The following results were measured using temporary mutations.

**When the `sharesMinted < minShares` check was deleted, three tests failed:**

- `test_FirstDepositRespectsMinShares`
- `test_MinSharesBoundary`
- `test_SkewAttackRevertsWhenMinSharesIsSet`

**When `<` was changed to `<=`, two tests failed:**

- `test_MinSharesBoundary`
- `test_FirstDepositRespectsMinShares`

The exact-boundary test demonstrates why the comparison matters. Requiring 10,001 shares when the pool calculates 10,000 must revert with `SlippageExceeded(10000, 10001)`. Requiring exactly 10,000 must succeed.

These results demonstrate that the guard rejects insufficient share output while permitting a deposit that exactly meets the caller's threshold.

### Caller-controlled threshold and residual risk

The pool enforces the threshold supplied by the caller. It does not independently determine whether that threshold represents an acceptable exchange for the depositor.

If the caller supplies `minShares = 0`, the protection is effectively disabled: a non-negative minted share amount cannot be less than zero.

The threshold should be calculated from a trustworthy quote and a consciously selected slippage tolerance. A quote computed before an attacker's skew can reject a manipulated deposit, provided the resulting minimum remains meaningful. A quote obtained after the reserves have already been manipulated can itself be misleading. A quote that is too old can also cause an otherwise honest transaction to revert.

**99% pre-skew quote hypothesis:** In the demonstrated balanced-pool setup, a trustworthy pre-skew quote is 10,000 shares. A 99% minimum is therefore 9,900. The manipulated deposit produces only 645 shares, so the guard rejects it.

A broader hypothesis is that a correctly obtained pre-skew quote and a 99% threshold constrain the accepted share shortfall to the selected tolerance. This does not yet establish a universal bound on token-denominated loss or attacker profitability across all pool states and deposit sizes. That requires a broader fuzzing experiment.

By contrast, if a quote is obtained after the skew, the quoted amount could be only 645 shares. A 99% threshold rounded down is approximately 638. The actual 645 shares then satisfy the threshold, and the manipulated deposit succeeds.

The caller must therefore use a meaningful minimum derived from a trustworthy pre-transaction expectation. The main pool enforces that requirement mechanically but cannot protect users who supply zero or an inadequately low threshold.

---

## F-03 — Reentrant liquidity withdrawal

| Field | Value |
|---|---|
| Severity | High (self-assessed) |
| Status | Mitigated in main implementation for the tested callback path |
| Impact | High — attacker gains 1,000 of each token; the honest LP can withdraw 0 of the 1,000 deposited units of each token (0%) |
| Likelihood | Medium — assumes callback-enabled token integrations are in scope; the attack requires a specific but realistic token integration and transaction sequence |
| Vulnerable implementation | `src/vulnerable/PoolReentrant.sol` |
| Mitigation | Checks-effects-interactions ordering in `Pool.removeLiquidity()` |
| Demonstration | `test_ReentrantWithdrawalDrainsPool()` in `ReentrancyAttackTest` |
| Fix verification | `test_NaiveReentrancyReverts()` and `test_SwallowedReentrancyGainsNothing()` |
| Reproduce (attack) | `forge test --match-contract ReentrancyAttackTest -vvv` |
| Reproduce (fix) | `forge test --match-contract RealPoolReentrancyTest -vvv` |

### What happens

The vulnerable `PoolReentrant.removeLiquidity()` calculates the attacker's withdrawal and calls `token0.transfer()` before updating accounting. The callback-enabled `HookToken` invokes the attacker's `onTokenReceived()` function during that transfer. The attacker re-enters `removeLiquidity(1000)` while its original 1,000 shares and the pool's 2,000/2,000 reserves are still recorded. The nested withdrawal therefore pays out a second 1,000 of each token before the outer call applies its own state updates.

### Demonstrated impact

| Measurement | Vulnerable pool | Corrected pool, swallowing attacker |
|---|---:|---:|
| Attacker final token0 / token1 | 2,000 / 2,000 | 1,000 / 1,000 |
| Attacker net token0 / token1 | +1,000 / +1,000 | 0 / 0 |
| Honest LP original deposit | 1,000 / 1,000 | 1,000 / 1,000 |
| Honest LP shares after attack | 900 | 900 |
| Honest LP withdrawable token0 / token1 | 0 / 0 | 900 / 900 |
| Honest LP recovery | 0% | 90% |
| Remaining pool reserves | 0 / 0 | 100 / 100 |

In the vulnerable pool, the honest LP's 900 shares remain recorded, but `totalShares` and both reserves become zero. The subsequent withdrawal reverts with a division-by-zero error. In the corrected pool, the locked 100 of each token remains after the honest LP withdraws.

### What the fix does

`Pool.removeLiquidity()` follows checks-effects-interactions: it reduces the provider's shares, total shares and both reserves before calling either token's `transfer()`. Consequently, a callback attempting a second withdrawal sees that the attacker has zero shares and cannot redeem them again.

### Evidence the tests can fail

When the four state updates in `Pool.removeLiquidity()` were moved below the two token transfers, **two tests failed:**

- `test_NaiveReentrancyReverts()`
- `test_SwallowedReentrancyGainsNothing()`

The first attacker lets the nested revert bubble up and roll back the entire transaction. The second catches the nested revert and allows the legitimate outer withdrawal to finish.

### Residual risk

The reproduction covers a recipient-side callback during token0 transfer. It does not test sender-side hooks during `transferFrom`, read-only reentrancy, or re-entry into `swap()` or `addLiquidity()`.

Real-world context: Tokenlon identifies the ERC-777 `tokensToSend` hook as the mechanism involved in the Uniswap and Lendf.Me reentrancy incidents and records the April 18–19, 2020 timeline in its [incident notice](https://support.tokenlon.im/hc/en-us/articles/360042172392-imBTC-fully-restored-transfer-trading-mint-and-redeem). PeckShield's [root-cause analysis](https://peckshield.medium.com/uniswap-lendf-me-hacks-root-cause-and-loss-analysis-50f3263dcc09), also quoted by [Security Affairs](https://securityaffairs.com/101895/cyber-crime/uniswap-lendf-me-hacked.html), explains that the sender-side `tokensToSend()` hook runs during ERC-777-compatible `transferFrom()`, before the token balance is updated. dForce's [April 2020 update](https://medium.com/dforcenet/dforce-ecosystem-update-april-2020-f2f620cfe5ed) confirms that Lendf.Me was attacked on April 19, approximately $25 million in assets were drained, and the callback mechanism enabled repeated supply and withdrawal before the balance was updated.

The historical incidents involved a sender-side callback during `transferFrom()`. This project's proof of concept exercises a different path: a recipient-side `onTokenReceived()` callback during `token0.transfer()`. The incidents provide context for callback-related reentrancy risk; they are not identical reproductions of this project's attack path.

The tested CEI ordering mitigates this demonstrated withdrawal path; it does not establish that every external-call path is protected.

---

## F-04 — Swap output rounded up

| Field | Value |
|---|---|
| Severity | Medium (self-assessed) |
| Status | Mitigated in main implementation |
| Impact | High — in the 900-swap test, the attacker gains 899,640 token1 and reduces the token1 reserve from 1,000,000 to 100,360 (89.964%) after selling back the accumulated token0 |
| Likelihood | Low — requires a highly skewed initial reserve ratio (1,000 token0 to 1,000,000 token1), repeated one-unit inputs and ceiling-rounded output. Live execution costs are not modelled. |
| Vulnerable implementation | `src/vulnerable/PoolRoundUp.sol` |
| Mitigation | Floor division in `Pool.getAmountOut()`; `ZeroOutput` separately rejects swaps that calculate to zero output |
| Demonstration | `test_DustSwapsDrainPoolWhenOutputRoundsUp()` in `RoundingAttackTest` |
| Fix verification | `test_RealPoolRejectsDustAndPunishesRoundTrips()`, `testFuzz_KNeverDecreases()` |
| Invariant property | `invariant_SwapsNeverLowerK()` |
| Reproduce | `forge test --match-path test/RoundingAttack.t.sol -vvv` |
| Reproduce (regression) | `forge test --match-test testFuzz_KNeverDecreases` and `forge test --match-test invariant_SwapsNeverLowerK` |

### What happens

The pool starts with reserves of 1,000 token0 and 1,000,000 token1. The attacker repeatedly sends one token1 unit, whose mathematically calculated token0 output is less than one whole unit. The vulnerable implementation rounds that fraction upward and transfers one token0 for every one-unit input. After 100 swaps, the attacker accumulates 100 token0 while spending 100 token1, reducing the pool's reserves to 900 token0 and 1,000,100 token1. The attacker then sells the accumulated token0 back into the pool for 99,740 token1, ending with a net gain of 99,640 token1. The same loop with 900 swaps yields a net gain of 899,640 token1 (see Demonstrated impact).

### One-unit rounding calculation

For one token1 input against the initial reserves:

`amountInWithFee = 1 * 997 = 997`

`numerator = 997 * 1,000 = 997,000`

`denominator = 1,000,000 * 1,000 + 997 = 1,000,000,997`

Therefore:

`exact output = 997,000 / 1,000,000,997 ≈ 0.000996999`

| Rounding method | Token0 output |
|---|---:|
| Floor | 0 |
| Ceiling | 1 |

The difference between zero and one whole token is the core of the attack.

### Demonstrated impact

The two vulnerable-pool tests assert the following results. Both use initial reserves of 1,000 token0 and 1,000,000 token1, and the attacker starts with 1,000 token1.

| Measurement | 100-swap test | 900-swap test |
|---|---:|---:|
| Dust swaps | 100 | 900 |
| Attacker token1 expenditure | 100 | 900 |
| Token0 accumulated | 100 | 900 |
| Reserves after dust swaps (token0 / token1) | 900 / 1,000,100 | 100 / 1,000,900 |
| Sell-back output | 99,740 | 900,540 |
| Final reserves (token0 / token1) | 1,000 / 900,360 | 1,000 / 100,360 |
| Final attacker token1 balance | 100,640 | 900,640 |
| Attacker net token1 profit | **99,640** | **899,640** |
| Initial constant product | 1,000,000,000 | 1,000,000,000 |
| Final constant product | 900,360,000 | 100,360,000 |
| Constant-product reduction | 99,640,000 (9.964%) | 899,640,000 (89.964%) |

The constant-product measurements above are final-state measurements after the attacker sells the accumulated token0 back into the pool. The 900-swap test demonstrates that the loss scales with repeated dust swaps under the same highly skewed initial reserve ratio.

Control: with balanced reserves of 1,000,000 / 1,000,000, the same 100 dust swaps and sell-back return exactly the 100 token1 spent (`test_DustSwapsDoNotProfitInBalancedPoolWhenOutputRoundsUp()`), so the profit above comes from the skewed price, where one token0 is worth about 1,000 token1.

### What the fix does

The vulnerable `PoolRoundUp.getAmountOut()` uses ceiling division:

`(numerator + denominator - 1) / denominator`

The main `Pool.getAmountOut()` uses ordinary integer floor division:

`amountOut = (amountInWithFee * reserveOut) / denominator`

Floor division prevents a fractional output from being rounded up to a whole token. This is the mitigation for the demonstrated extraction attack.

The separate `ZeroOutput` check rejects a swap when floor division produces no output.

Without this check, a swap whose floor-divided output is zero would still collect the trader's input and transfer nothing back: the pool would keep one token1 and the trader would receive zero token0. This was confirmed in a temporary local experiment that is not part of the repository.

The main implementation's swap arithmetic is intended to ensure that the constant product never decreases due to a swap. This property is checked by `testFuzz_KNeverDecreases()` and `invariant_SwapsNeverLowerK()`.

### Evidence from an isolated mutation

To test whether the regression suite detects this specific fault, only the output calculation in `Pool.getAmountOut()` was temporarily changed from floor division to ceiling division:

`(numerator + denominator - 1) / denominator`

The remaining pool logic was left unchanged.

Running `forge test` produced:

| Result | Count |
|---|---:|
| Unit and fuzz tests passed | 40 |
| Unit and fuzz tests failed | 14 |
| Total unit and fuzz tests | 54 |
| Invariant properties failed | 1 of 5 |

The 14 failing unit and fuzz tests were:

- `testFuzz_KNeverDecreases`
- `testFuzz_SwapKeepsInvariants`
- `testFuzz_SwapSequenceKeepsInvariants`
- `test_BigTrade`
- `test_DepositThatRoundsToZeroSharesReverts`
- `test_RemoveAfterSwapEarnsFees`
- `test_RemoveThatRoundsToZeroReverts`
- `test_SmallTrade`
- `test_SwapAppliesFee`
- `test_SwapMatchesHandTrace`
- `test_SwapRejectsZeroOutput`
- `test_SwapRevertsBelowMinAmountOut`
- `test_SwapToken1ForToken0`
- `test_RealPoolRejectsDustAndPunishesRoundTrips`

Two names need clarification. `test_DepositThatRoundsToZeroSharesReverts()` and `test_RemoveThatRoundsToZeroReverts()` both failed at reserve assertions immediately after their setup swaps. Their expected token1 reserves were 668 and 168 respectively; ceiling rounding changed those values to 667 and 167. Neither test reached its intended deposit or withdrawal operation.

The invariant suite also detected the mutation: `invariant_SwapsNeverLowerK()` failed, while the other four invariant properties passed. The run executed 256 invariant runs and 12,800 calls with zero reverts. The shrunk failing sequence was:

`swap(13483, false, 0)`

After the experiment, the original floor-division implementation was restored. `git status --short` was empty.

### Real-pool round-trip comparison

In `test_RealPoolRejectsDustAndPunishesRoundTrips()`, a one-unit token1 input produces zero token0 output and is rejected with `Pool.ZeroOutput`.

The attacker then performs a larger round trip, starting with 2,000 token1 against reserves of 1,000 token0 and 1,000,000 token1.

**First leg: token1 to token0**

The fee-adjusted input is 1,994,000. The exact output is:

`1,994,000,000 / 1,001,994,000 ≈ 1.990031876 token0`

The pool uses floor division and transfers only 1 token0.

After this swap, the reserves are 999 token0 and 1,002,000 token1.

**Second leg: token0 back to token1**

For the actual input of 1 token0, the exact output is:

`998,994,000 / 999,997 ≈ 998.996996991 token1`

Floor division transfers 998 token1.

The attacker therefore starts with 2,000 token1 and finishes with 998 token1, losing **1,002 token1**.

**Decomposing the loss**

With both swap outputs calculated without integer truncation, while retaining the 0.3% fee on each leg, the round trip returns approximately 1,988.041773170 token1. The resulting fee-related loss is approximately 11.958226830 token1.

The additional loss caused by floor rounding consists of:

- Approximately 989.044776179 token1 equivalent from rounding the first-leg output down from 1.990031876 to 1 token0.
- Approximately 0.996996991 token1 from rounding the second-leg output down from 998.996996991 to 998.

These components sum to the actual 1,002 token1 loss. This decomposition is specific to the tested reserves and trade sizes; it distinguishes the two swap fees from the value retained through integer output truncation.

### Residual risk

The demonstration does not model real-chain gas costs, transaction fees, competition, or execution constraints. The dust swaps are calls inside local Foundry tests, not an economic simulation of 100 or 900 separately submitted mainnet transactions.

Consequently, the measured profits (99,640 token1 in the 100-swap test and 899,640 token1 in the 900-swap test) are contract-level test results, not proof that the attack would remain profitable on a live chain. Whether the profit exceeds transaction costs under a specific network, token valuation and execution environment has not been established.

---

The findings document describes deliberately reproduced behaviours in educational implementations and the mitigations tested in the main pool. It is not an independent security assessment or a guarantee against unknown vulnerabilities.
