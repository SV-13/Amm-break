# Findings

**Scope:** `src/Pool.sol` (constant-product pool with a 0.3% fee) and intentionally vulnerable variants in `src/vulnerable/`.

**Assessment status:** Not independently audited. Educational project; no mainnet deployment.

## Severity methodology

Severity is self-assessed using Impact × Likelihood.

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| High | Medium | High | Critical |
| Medium | Low | Medium | High |
| Low | Low | Low | Medium |

The ratings below are project assessments rather than formal audit ratings.

## Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| F-01 | First-depositor share inflation | High (self-assessed) | Partially mitigated (see F-02) |
| F-02 | Missing minimum-share slippage protection | High (self-assessed) | Mitigated in main implementation; caller-dependent |
| F-03 | Reentrant liquidity withdrawal | High (self-assessed) | Mitigated in main implementation for the tested callback path |

---

## F-01 — First-depositor share inflation

| Field | Value |
|---|---|
| Severity | High (self-assessed) |
| Status | Partially mitigated (see F-02) |
| Impact | High — a liquidity provider can lose substantial amounts of deposited assets |
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
| Impact | High — the attacker withdraws 2,000 of each token while the honest LP's 900 shares become unredeemable |
| Likelihood | Medium — requires a token that invokes a recipient callback during transfer and an attacker contract able to re-enter the pool |
| Vulnerable implementation | `src/vulnerable/PoolReentrant.sol` |
| Mitigation | Checks-effects-interactions ordering in `Pool.removeLiquidity()` |
| Demonstration | `test_ReentrantWithdrawalDrainsPool()` in `ReentrancyAttackTest` |
| Fix verification | `test_NaiveReentrancyReverts()` and `test_SwallowedReentrancyGainsNothing()` in `RealPoolReentrancyTest` |
| Reproduce (attack) | `forge test --match-contract ReentrancyAttackTest -vvv` |
| Reproduce (fix) | `forge test --match-contract RealPoolReentrancyTest -vvv` |

### What happens

The vulnerable pool calculates a withdrawal but transfers token0 before updating the attacker's shares, total shares or reserves. The pool's token0 is a callback-enabled `HookToken`; when it transfers tokens to the attacker contract, it invokes `onTokenReceived()`, which calls `removeLiquidity()` again. Because the original withdrawal has not updated state, the nested call still sees 1,000 attacker shares and reserves of 2,000 token0 and 2,000 token1. Both withdrawals therefore transfer 1,000 of each token, draining the pool.

### Demonstrated impact

The test starts with:

| Item | Value |
|---|---:|
| Honest LP shares | 900 |
| Attacker shares | 1,000 |
| Total shares | 2,000 |
| Pool reserve0 | 2,000 |
| Pool reserve1 | 2,000 |

After the reentrant attack, the test asserts:

| Item | Final value |
|---|---:|
| Attacker token0 balance | 2,000 |
| Attacker token1 balance | 2,000 |
| Attacker shares | 0 |
| Honest LP shares | 900 |
| Total shares | 0 |
| Pool reserve0 | 0 |
| Pool reserve1 | 0 |
| Pool token0 balance | 0 |
| Pool token1 balance | 0 |

The attacker started with 1,000 of each token and deposited those tokens into the pool. Their final balances of 2,000 each represent a net gain of 1,000 of each token.

The honest LP still has 900 recorded shares, but the pool's total share supply and reserves have both reached zero. When the honest LP attempts to withdraw 900 shares, the withdrawal calculation divides by `totalShares == 0` and reverts with a division-by-zero error. The LP's recorded shares no longer correspond to redeemable assets.

### What the fix does

The vulnerable `PoolReentrant.removeLiquidity()` performs external token transfers before applying the withdrawal effects.

The corrected `Pool.removeLiquidity()` follows checks-effects-interactions:

1. It verifies the provider's share balance and calculates the withdrawal amounts.
2. It reduces `shares[msg.sender]`.
3. It reduces `totalShares`, `reserve0` and `reserve1`.
4. Only then does it call `token0.transfer()` and `token1.transfer()`.

When the token0 callback attempts the nested withdrawal, the attacker already has zero shares. The nested call fails with:

`InsufficientShares(0, 1000)`

It cannot withdraw the same shares a second time.

### Evidence the tests can fail

The vulnerable implementation reproduces the drain in:

`test_ReentrantWithdrawalDrainsPool()`

The corrected implementation passes two distinct attacker-strategy tests:

- `test_NaiveReentrancyReverts()` — the attacker lets the nested `InsufficientShares(0, 1000)` revert bubble up. This rolls back the entire outer transaction, including the callback's state changes.
- `test_SwallowedReentrancyGainsNothing()` — the attacker catches the nested revert, allowing the legitimate outer withdrawal to complete. The attacker receives only 1,000 of each token, and the honest LP successfully withdraws 900 of each.

The vulnerable state-update ordering caused both `test_NaiveReentrancyReverts()` and `test_SwallowedReentrancyGainsNothing()` to fail during the M4 mutation experiment.

The original invariant handler used ordinary tokens and did not exercise a hostile transfer callback. After a `HookToken` and reentrant attacker were added, the share-accounting invariant detected the tested M4 violation; the full mutation history is documented in the Level 4 scoreboard.

### Residual risk

The reproduction uses a recipient-side callback when token0 transfers to the attacker contract. It does not test sender-side token hooks during `transferFrom`, read-only reentrancy, re-entry into `swap()`, or re-entry into `addLiquidity()`.

The tests establish the checks-effects-interactions protection for the exercised withdrawal path. They do not establish that every possible callback-capable token or external-call path is safe.

