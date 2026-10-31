# Findings

**Scope:** `src/Pool.sol` (constant-product pool with a 0.3% fee) and intentionally vulnerable variants in `src/vulnerable/`.

**Assessment status:** Not independently audited. Educational project; no mainnet deployment.

**Severity methodology:** Self-assessed using Impact × Likelihood.

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

The main pool's 100-share minimum-liquidity lock prevents the original 4/4 initialization because its geometric-mean share amount is only four. However, the lock alone does not eliminate the skew attack when minimum-share slippage protection is absent. The Level 3 comparison reproduced the attack against a locked pool without `minShares`:

| Measurement | No lock (`PoolNoLock`) | Lock, no `minShares` |
|---|---:|---:|
| Attacker opening deposit | 4 / 4 | 1,000 / 1,000 (4 / 4 reverts) |
| Attacker skew deposit | 30,000 / 1 | 30,000 / 1,000 |
| Victim shares minted | 1 | 645 |
| Victim net (token0 / token1) | −3,332 / −8,332 | −2 / −7,074 |
| Attacker net (token0 / token1) | +3,332 / +8,332 | −1,549 / +6,620 |

At the pool's opening 1:1 reference price, the locked-pool attacker is still nominally net-positive: −1,549 + 6,620 = +5,071. The victim still loses 7,074 token1. These figures show that the lock blocks the tiny-supply setup but does not replace per-deposit `minShares` protection.

### Root cause and mitigation

In `PoolNoLock`, `MINIMUM_LIQUIDITY` is zero, so the first provider receives the entire initial share supply. Later deposits are priced using the smaller of the two reserve ratios, allowing a deliberately skewed pool to issue few shares to a victim.

The main `Pool.addLiquidity()` implementation sets `MINIMUM_LIQUIDITY` to 100, rejects an initial share amount less than or equal to that lock, subtracts the lock from the provider's minted shares, and includes the locked amount in `totalShares`. This prevents the demonstrated tiny first deposit, but a meaningful `minShares` value is still required to protect later deposits against an unacceptable share calculation.

### Regression coverage

- `test_TinyFirstDepositReverts()`
- `test_FirstDepositMintsSharesAndLocksMinimum()`
- `test_FirstDepositAtMinimumLiquidityBoundaryReverts()`
- `test_FirstDepositJustAboveMinimumLiquidityBoundaryMintsOneShare()`
- `test_SkewAttackRevertsWhenMinSharesIsSet()`

### Residual risk

The minimum-liquidity lock is only one layer of protection. It does not by itself guarantee that later depositors receive an acceptable number of shares. The locked-pool comparison demonstrates the remaining risk when `minShares` protection is absent. The separate minimum-share protection finding will be documented as F-02.
