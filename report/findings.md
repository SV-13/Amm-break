# Findings

**Scope:** `src/Pool.sol` (constant-product pool with a 0.3% fee) and the intentionally vulnerable variants in `src/vulnerable/`.

**Assessment status:** Not independently audited. Educational project; no mainnet deployment.

**Severity methodology:** Severity is self-assessed using Impact × Likelihood. Ratings are project assessments, not formal audit ratings.

---

## F-01 — First-depositor share inflation

| Field | Value |
|---|---|
| Severity | High (self-assessed) |
| Impact | High — a victim can lose a substantial portion of both deposited assets |
| Likelihood | Medium — requires control of initial pool creation and a subsequent victim deposit |
| Vulnerable variant | `src/vulnerable/PoolNoLock.sol` |
| Root cause | No minimum liquidity is permanently locked on the first deposit |
| Mitigation | `src/Pool.sol:17`, `src/Pool.sol:49–57` and `src/Pool.sol:78–80` |
| Demonstration | `test/FirstDepositorAttack.t.sol` |
| Reproduce | `forge test --match-contract FirstDepositorAttackTest -vvv` |
| Regression coverage | `test_TinyFirstDepositReverts`, `test_FirstDepositMintsSharesAndLocksMinimum`, `test_FirstDepositAtMinimumLiquidityBoundaryReverts`, `test_FirstDepositJustAboveMinimumLiquidityBoundaryMintsOneShare` |

### What happens

The vulnerable pool does not permanently lock any minimum liquidity during its first deposit. An attacker exploits this by initializing the pool with only 4 token0 and 4 token1, receiving all four initial LP shares.

The attacker then adds 30,000 token0 and just 1 token1. This skews the reserves significantly while increasing the attacker's ownership to five out of five shares.

When the victim subsequently deposits 10,000 of each token, the smaller token0 reserve ratio determines the shares minted. The victim receives only one share, leaving the attacker with five of the six total shares.

The attacker withdraws first and captures most of the assets deposited by the victim.

### Demonstrated impact

The test `test_FirstDepositorAttackStealsFromVictim()` verifies the following sequence.

**1. Initial attacker deposit**

| Item | Amount |
|---|---:|
| Token0 deposited | 4 |
| Token1 deposited | 4 |
| Shares minted | 4 |
| Total shares | 4 |

The attacker owns 100% of the initial LP shares.

**2. Attacker skews the pool**

The attacker deposits another 30,000 token0 and 1 token1.

| Item | Amount |
|---|---:|
| Additional token0 | 30,000 |
| Additional token1 | 1 |
| Additional shares minted | 1 |
| Attacker shares | 5 |
| Total shares | 5 |
| Reserve0 | 30,004 |
| Reserve1 | 5 |

**3. Victim deposits**

The victim deposits 10,000 of each token.

| Item | Amount |
|---|---:|
| Token0 deposited | 10,000 |
| Token1 deposited | 10,000 |
| Shares minted | 1 |
| Attacker shares | 5 |
| Victim shares | 1 |
| Total shares | 6 |
| Reserve0 | 40,004 |
| Reserve1 | 10,005 |

The attacker owns five-sixths of the pool despite the victim depositing 10,000 of each asset.

**4. Attacker withdraws first**

The attacker burns five shares and receives:

| Asset | Withdrawn |
|---|---:|
| Token0 | 33,336 |
| Token1 | 8,337 |

The remaining pool contains:

| Asset | Remaining reserve |
|---|---:|
| Token0 | 6,668 |
| Token1 | 1,668 |

**5. Victim withdraws**

The victim burns the remaining share and receives:

| Asset | Withdrawn |
|---|---:|
| Token0 | 6,668 |
| Token1 | 1,668 |

The pool is now empty.

**6. Net attacker gains and victim losses**

The test asserts the following final balances:

| Asset | Attacker net gain | Victim net loss |
|---|---:|---:|
| Token0 | 3,332 | 3,332 |
| Token1 | 8,332 | 8,332 |

The attacker's gains exactly match the victim's losses, asset by asset.

Relative to the victim's 10,000-unit deposit of each asset, the victim loses 33.32% of token0 and 83.32% of token1.

These are token quantities, not a USD valuation. No external token-price assumption is made.

The attack test passes and asserts each intermediate reserve, share balance, withdrawal amount and final wallet balance.

### Root cause

The vulnerable implementation defines:

`MINIMUM_LIQUIDITY = 0`

in `src/vulnerable/PoolNoLock.sol`.

During the first deposit, it calculates:

`initialShares = sqrt(amount0 * amount1)`

With a 4/4 deposit, this produces four shares.

Because no minimum shares are locked, the first provider receives all four shares and controls the entire initial pool supply.

The attacker can then manipulate the reserve proportions through an unbalanced deposit. Subsequent liquidity providers receive shares based on the smaller of the two reserve ratios, which can result in significantly fewer shares than their deposit size might suggest.

The underlying problem is that the first provider can establish the initial share supply without any permanently locked minimum liquidity.

### Why the mitigation works

The main implementation in `src/Pool.sol` defines:

`MINIMUM_LIQUIDITY = 100`

During the first deposit, the pool calculates the geometric mean of the deposited amounts and rejects deposits when:

`initialShares <= MINIMUM_LIQUIDITY`

For an accepted first deposit, it mints:

`sharesMinted = initialShares - MINIMUM_LIQUIDITY`

It then sets:

`totalShares = sharesMinted + MINIMUM_LIQUIDITY`

The 100 locked shares are included in total supply but are not credited to the first provider. They cannot be withdrawn by an ordinary liquidity provider.

The initial depositor therefore bears the economic cost of the locked liquidity: some of the initial pool's share supply is permanently unavailable to them.

For the attack's original 4/4 seed:

`sqrt(4 * 4) = 4`

Since 4 is less than the required 100 minimum, the main pool reverts before the attacker can establish the vulnerable tiny initial supply.

The lock also ensures that an accepted first deposit does not allocate the entire initial share supply to the first provider.

This raises the cost of manipulating a newly initialized pool and prevents the demonstrated zero-lock setup.

### Tests demonstrating the mitigation

The following tests exercise the corrected `Pool` implementation:

- `test_TinyFirstDepositReverts()` — verifies that a tiny initial deposit is rejected.
- `test_FirstDepositMintsSharesAndLocksMinimum()` — verifies the first-deposit share calculation and locked minimum.
- `test_FirstDepositAtMinimumLiquidityBoundaryReverts()` — verifies that a deposit producing exactly the minimum initial shares is rejected and that the pool's state remains unchanged.
- `test_FirstDepositJustAboveMinimumLiquidityBoundaryMintsOneShare()` — verifies that a 101/101 deposit succeeds, mints one provider share and leaves total shares at 101.

The two boundary tests were also checked against the deliberately mutated `<` condition. The exact-boundary rejection test failed under that mutation, confirming that the regression test detects the off-by-one defect.

### Severity justification

**Self-assessed severity: High.**

The impact is high because the demonstrated attack transfers 3,332 token0 and 8,332 token1 away from the victim in one liquidity interaction. The likelihood is conditional: an attacker must control initial pool creation and arrange for a victim to deposit afterwards. Nevertheless, the scale of the demonstrated asset loss justifies treating the attack as high impact.

### Residual risk

The minimum-liquidity lock addresses the demonstrated first-depositor share-inflation setup. It is not a general guarantee that every subsequent liquidity deposit receives an acceptable number of shares.

A fixed initial liquidity lock does not replace per-deposit slippage protection. The caller must supply a meaningful `minShares` value so that an unexpected or manipulated share calculation can be rejected.

The separate minimum-share protection and its limitations are documented in **[F-02 — Liquidity deposit slippage and minimum-share guarantees](#f-02-liquidity-deposit-slippage-and-minimum-share-guarantees)**.

The lock also does not establish that every possible reserve-manipulation, callback or reentrancy path is safe. Those concerns require separate controls and testing.

