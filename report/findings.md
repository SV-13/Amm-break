# Findings

**Scope:** `src/Pool.sol` (constant-product pool with a 0.3% fee) and intentionally vulnerable variants in `src/vulnerable/`.

**Assessment status:** Not independently audited. Educational project; no mainnet deployment.

**Severity methodology:** Self-assessed using Impact × Likelihood.

## Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| F-01 | First-depositor share inflation | High (self-assessed) | Partially mitigated (see F-02) |
| F-02 | Missing minimum-share slippage protection | High (self-assessed) | Mitigated in main implementation; caller-dependent |

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
| Demonstration | `test/FirstDepositorAttack.t.sol` |
| Reproduce | `forge test --match-contract FirstDepositorAttackTest -vvv` |

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

The locked-pool comparison reproduced the following result:

| Measurement | No lock (`PoolNoLock`) | Lock, no `minShares` |
|---|---:|---:|
| Attacker opening deposit | 4 / 4 | 1,000 / 1,000 (4 / 4 reverts) |
| Attacker skew deposit | 30,000 / 1 | 30,000 / 1,000 |
| Victim shares minted | 1 | 645 |
| Victim net (token0 / token1) | −3,332 / −8,332 | −2 / −7,074 |
| Attacker net (token0 / token1) | +3,332 / +8,332 | −1,549 / +6,620 |

At the pool's opening 1:1 reference price, the locked-pool attacker is still nominally net-positive: −1,549 + 6,620 = +5,071. The victim still loses 7,074 token1.

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
| Impact | High — a victim can receive substantially fewer LP shares than expected and lose a large portion of deposited assets |
| Likelihood | Medium — requires reserve manipulation and an absent, zero or insufficient minimum-share threshold |
| Vulnerable implementation | `src/vulnerable/PoolNoMinShares.sol` |
| Mitigation | `minShares` parameter and `sharesMinted < minShares` check in `Pool.addLiquidity()` |
| Demonstration | `test/MinSharesFix.t.sol` |
| Reproduce | `forge test --match-contract MinSharesFixTest -vvv` |
| Additional comparison | `forge test --match-contract LockedPoolAttackTest -vvv` |

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

In `test_SkewAttackRevertsWhenMinSharesIsSet()`, the victim requires at least 9,900 shares. The pool calculates 645, resulting in the expected revert:

`SlippageExceeded(645, 9900)`

The first value, 645, is the number of shares actually calculated by the pool. The second value, 9,900, is the minimum number requested by the victim.

The test also verifies that a rejected deposit leaves both wallet balances, reserves, total shares, victim shares and pool token balances unchanged.

The guard does not reject honest deposits automatically. `test_HonestDepositPassesWithMinShares()` verifies that a balanced deposit mints 10,000 shares and succeeds with a minimum requirement of 9,900.

### Evidence the tests can fail

The test suite exercises both sides of the comparison.

- In `test_SkewAttackRevertsWhenMinSharesIsSet()`, the manipulated deposit must revert with `SlippageExceeded(645, 9900)`.
- In `test_MinSharesBoundary()`, requiring 10,001 shares when the pool calculates 10,000 must revert with `SlippageExceeded(10000, 10001)`.
- The same test then verifies that exactly 10,000 shares succeeds when `minShares` is 10,000.

If the `sharesMinted < minShares` check is deleted, the expected reverts do not happen.

If the comparison changes from `<` to `<=`, the exact-boundary deposit is incorrectly rejected because 10,000 shares equals the requested minimum of 10,000.

These tests therefore verify both rejection of insufficient shares and acceptance of the exact valid boundary.

### Caller-controlled threshold and residual risk

The pool enforces the threshold supplied by the caller. It does not independently determine whether that threshold represents an acceptable exchange for the depositor.

If the caller supplies `minShares = 0`, the protection is effectively disabled: a non-negative minted share amount cannot be less than zero.

The threshold should be calculated from a trustworthy quote and a consciously selected slippage tolerance. A quote computed before an attacker's skew can protect against the manipulation by preserving a higher minimum, although it can also become stale and cause a legitimate transaction to revert. A quote obtained after the reserves have already been manipulated can itself be misleading.

**99% quote example:** The outcome depends on when the quote is obtained.

- If the victim's balanced-pool quote is 10,000 shares, a 99% minimum is 9,900. An actual calculation of 645 fails the check, so the victim's deposit reverts and the attacker extracts nothing from that deposit.
- If the quote is obtained after the attacker's skew, the quote is only 645. A 99% minimum is approximately 638 shares when rounded down. The actual 645 shares satisfy that threshold, so the deposit succeeds. The locked-pool comparison's demonstrated outcome remains possible: the victim loses 2 token0 and 7,074 token1, while the attacker gains 6,620 token1 and loses 1,549 token0.

Therefore, a 99% tolerance does not independently guarantee protection. The quality and timing of the quote matter just as much as the percentage chosen.

The caller must use a meaningful minimum derived from a trustworthy pre-transaction expectation. The main pool enforces that requirement mechanically but cannot protect users who deliberately or accidentally supply zero or an inadequately low threshold.

