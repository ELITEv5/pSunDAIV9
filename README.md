# pSunDAI V9

**Autonomous · Ownerless · Immutable · Censorship-Resistant · PulseChain**

pSunDAI is a WPLS-collateralized autonomous stable asset on PulseChain. Users lock PLS (or WPLS) as collateral and mint pSunDAI — a USD-pegged token backed by over-collateralization, a stability fee, and a 5-pool PulseX liquidity-weighted oracle. There are no admin keys, no upgradeability, and no governance. Once deployed, the protocol runs forever.

V9 responds to an external security review that found two **confirmed, exploitable** flaws in V8 — not theoretical concerns, working attacks against the live contract — plus one structural gap. All three are fixed here, and V9 adds a Stability Pool so liquidations no longer depend on keepers reselling collateral into thin PulseChain DEX liquidity.

> *"The bank is immutable Solidity. The monetary policy is enforced by mathematics."*

---

## Table of Contents

1. [Running this off your own computer](#running-this-off-your-own-computer)
2. [What is pSunDAI?](#what-is-psundai)
3. [Why V9 exists — the V8 findings](#why-v9-exists--the-v8-findings)
4. [V9 Improvements over V8](#v9-improvements-over-v8)
5. [The Oracle (5-Pool Liquidity-Weighted TWAP)](#the-oracle-5-pool-liquidity-weighted-twap)
6. [The Stability Pool](#the-stability-pool)
7. [How to Use](#how-to-use)
8. [Vault Health Zones](#vault-health-zones)
9. [Liquidations](#liquidations)
10. [Stability Fee, Surplus Buffer, and Stability Pool Yield](#stability-fee-surplus-buffer-and-stability-pool-yield)
11. [Debt Ceiling](#debt-ceiling)
12. [Emergency Functions](#emergency-functions)
13. [Protocol Tools](#protocol-tools)
14. [System Invariants](#system-invariants)
15. [Deployed Contracts](#deployed-contracts)
16. [Compiling](#compiling)
17. [Deploy Order](#deploy-order)
18. [Security Model](#security-model)
19. [Frontend Files](#frontend-files)

---

## Running this off your own computer

This app is intentionally self-contained — no build step, no CDN dependency, no server-side component. That's not an accident: censorship resistance is a design goal for every protocol in this system, and a frontend that only works when a specific company's server is up isn't actually censorship-resistant, no matter how immutable the contracts underneath it are.

**Three ways to run it, in order of how little you need to trust:**

1. **Double-click `index.html`.** Every asset reference in this folder (`ethers.umd.min.js`, `sundailogo.png`, `favicon.svg`) is a relative path, `ethers.js` is bundled locally rather than pulled from a CDN, and there are no `fetch()` calls to anywhere — the contract ABIs are inlined directly in the HTML. Opening the file directly via `file://` works. The one thing that won't work over `file://` is the service worker (browsers require a secure context for those) — the page degrades gracefully, it just won't get the offline-caching layer.
2. **Run a trivial local server**, if your browser is stricter about `file://` wallet extensions (some are): `python3 -m http.server 8080` from inside this folder, then open `http://localhost:8080/index.html`.
3. **Pull it from IPFS** once pinned (see below) — content-addressed, no single host, no company that can take it down.

None of these require trusting GitHub, a hosting provider, or anyone's server. Your wallet talks directly to PulseChain; this folder is just the interface.

---

## What is pSunDAI?

pSunDAI is a CDP (Collateralized Debt Position) protocol on PulseChain. Users lock WPLS (or native PLS) as collateral and borrow pSunDAI against it. Each pSunDAI targets **$1 USD** — the peg is enforced by:

1. **Over-collateralization** — minimum 150% CR to mint
2. **Stability fee** — 0.5% APY applied to debt, funding both a bad-debt backstop and Stability Pool yield
3. **Liquidations** — vaults below 110% CR are liquidated, preferentially absorbed atomically by the Stability Pool, with keeper liquidation as fallback

The protocol does not require any human intervention to maintain the peg. There is no governance, no admin, no pausing.

> **Note:** pSunDAI does not include a redemption mechanism. Peg maintenance relies on the stability fee, Stability Pool, and liquidation mechanisms.

---

## Why V9 exists — the V8 findings

V8 was reviewed after deployment, before any real value entered it (zero live vaults). The review found:

**H1 — `clearBadDebt()` gave away 100% of a vault's collateral for free.** Once collateral value dipped under 100% of debt, the caller received all of the vault's collateral at zero cost, and the check that gated this read the **manipulable raw spot price** — an attacker could suppress spot on the underlying PulseX pools to trigger this on an otherwise-healthy vault and walk away with its collateral.

**H2 — the spot-liquidation arm had no ceiling on manipulation profit.** Once the spot-liquidation arm activated (a sustained divergence from TWAP), liquidation rewards were computed directly from the raw, unbounded spot price. A suppressed price directly and proportionally inflated the payout, with no limit on how far it could be pushed.

**Structural gap — no real liquidation throughput independent of DEX depth, and no yield.** V8's only liquidation path required a keeper to already hold pSunDAI and resell seized collateral into the same thin pools the oracle reads from. The 0.5% stability fee accumulated in a `surplusBuffer` counter with no path to any beneficiary — real revenue that nobody could ever claim.

Given V8 had zero live vaults, the fix was a redeploy rather than an in-place patch (the contracts are immutable — patching in place was never possible). V9 is that redeploy.

---

## V9 Improvements over V8

### Fix for H1 — `clearBadDebt` requires real, pro-rata repayment
`clearBadDebt(address user, uint256 repayAmount)` (signature changed — now takes a repay amount). The caller must burn `repayAmount` pSunDAI and receives collateral **strictly pro-rata**: `collateralOut = vault.collateral * repayAmount / vault.debt`, with **no bonus**. Since the vault is underwater by definition when this is callable, a caller can never receive collateral worth more than they paid — this removes the free-value-extraction path entirely rather than just capping it. The underwater check itself also now reads the new clamped liquidation price (see H2 fix), closing the manipulation vector on the trigger, not just the payout.

### Fix for H2 — liquidation price is now clamped to TWAP
New oracle function `getLiquidationPrice()` returns the spot median **hard-clamped to within 15% of the committed TWAP** once the spot-liquidation arm has confirmed a sustained divergence. Previously, once that arm activated, raw spot was used directly with no bound. Now, no matter how far or how long an attacker suppresses spot, the price actually used for liquidation eligibility and reward calculation cannot diverge from TWAP by more than 15% — bounding manipulation profit to a small, fixed amount instead of an open-ended one.

### Fix for the structural gap — Stability Pool + fee yield
See [The Stability Pool](#the-stability-pool) and [Stability Fee, Surplus Buffer, and Stability Pool Yield](#stability-fee-surplus-buffer-and-stability-pool-yield) below. In short: liquidations are now absorbed atomically by pre-deposited pSunDAI instead of depending on keeper capital and DEX resale, and the stability fee now mints directly into the pool as real, continuous yield for depositors instead of an inert accounting counter.

### Oracle hardening, corrected against real pool data
- **`MIN_RESERVE_USD`: $1,000 → $10,000.** (Not the $25,000 first proposed during review — that number was checked against the live PulseX pools at deploy time and found to exclude one of the five entirely while leaving another with only 23% margin above the cutoff, an uncomfortably tight fit for an immutable parameter. $10,000 gives every pool comfortable headroom against real, fluctuating depth.)
- **New `MIN_VALID_POOLS = 3`.** Both the TWAP median and spot median now require at least 3 of the 5 pools to be valid before returning a nonzero price, instead of letting 1-2 remaining pools set the price alone once others are drained or excluded.
- **`SPOT_CONFIRM_TIME`: 30min → 90min.** Paired with the higher reserve floor, raises the cost and duration of sustaining a manipulated price.
- **`SAFE_CAPACITY_MULTIPLIER`: 20 → 5.** V8's 20x authorized system debt up to 20x actual DEX stable-liquidity — a level that guarantees slippage-driven bad debt if liquidators ever needed to dump collateral at scale on thin PulseChain pools. 5x is a materially tighter, more defensible multiple of real depth.

### What didn't change
`COLLATERAL_RATIO` 150%, `LIQUIDATION_RATIO` 110%, Dutch auction bonus 2-5% over 3 hours, dynamic ceiling/per-vault cap architecture (now inheriting the tighter oracle multiplier), emergency exits, vault enumeration, no liquidation cooldown, `liquidateWithFlashMint`'s flash-mint-free design. All economically load-bearing v8 logic that wasn't implicated in the findings above was left alone.

---

## The Oracle (5-Pool Liquidity-Weighted TWAP)

Same dual-track design as V8 (conservative TWAP for minting/withdrawal safety, real-time spot warning for liquidation eligibility during confirmed crashes), hardened per above, plus the new clamped liquidation-price read.

**Price sources (same 5 PulseX pools V8 used — already live, no re-derivation):**
- 2 × WPLS/DAI pools (v1, v2)
- 2 × WPLS/USDC pools (v1, v2)
- 1 × WPLS/USDT pool

**TWAP constants (unchanged from V8):**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `CONFIRM_TIME_DOWN` | 4 hours | Confirm before accepting >1% downward move |
| `CONFIRM_TIME_UP` | 30 min | Confirm before accepting >5% upward move |
| `STEP_SIZE_DOWN_BPS` | 300 (3%) | Max step per update going down |
| `STEP_SIZE_UP_BPS` | 1000 (10%) | Max step per update going up |
| `INSTANT_UPDATE_DOWN_BPS` | 100 (1%) | ≤1% down: instant, subject to cumulative check |
| `INSTANT_UPDATE_UP_BPS` | 500 (5%) | ≤5% up: instant, subject to cumulative check |
| `STAIRCASE_WINDOW` | 30 min | Rolling window for cumulative drift check |

**Hardened constants (V9):**
| Parameter | V8 | V9 | Why |
|-----------|-----|-----|-----|
| `MIN_RESERVE_USD` | $1,000 | **$10,000** | Raises the cost of getting a pool counted at all; calibrated against real observed pool depth ($17.6k-$376k across the 5 pools at deploy time), not picked in the abstract |
| `MIN_VALID_POOLS` | *(none)* | **3** | Stops a minority of manipulated/drained pools from dominating the weighted median |
| `SPOT_CONFIRM_TIME` | 30 min | **90 min** | Raises the duration a manipulation must be sustained |
| `SAFE_CAPACITY_MULTIPLIER` | 20 | **5** | System debt capacity is now a much tighter multiple of real DEX depth |
| `MAX_SPOT_DEVIATION_BPS` | *(none)* | **1500 (15%)** | New — hard-clamps the liquidation price to within 15% of TWAP, the direct H2 fix |

**Liquidity-derived capacity:**
`maxSafeDebt()` = 5x the rolling-minimum (24h window) combined stable-side reserves across whichever pools individually clear `MIN_RESERVE_USD`. This is dynamic and re-read live every time it's called — it automatically tracks real PulseChain liquidity growth (or contraction) with zero contract changes ever needed. See [Debt Ceiling](#debt-ceiling) for the concrete numbers at deploy time.

**Oracle states (`getPriceStatus` returns):**
| Field | Description |
|-------|-------------|
| `currentPrice` | TWAP committed price — used for vault safety checks |
| `marketPrice` | Current 5-pool liquidity-weighted spot median |
| `divergenceBps` | Divergence between TWAP and spot in basis points |
| `inConfirmation` | A price update is pending confirmation |
| `confirmTimeRemaining` | Time until confirmation completes |
| `targetPrice` | Target being confirmed |
| `spotWarningActive` | Spot is 5%+ below TWAP |
| `spotLiquidationEnabled` | Warning active for 90+ min — liquidations use the clamped spot price |

**New: `getLiquidationPrice()`** — returns `(price, isSpot)`. When the spot arm is active, `price` is spot clamped to within 15% of TWAP; otherwise it's TWAP itself. This is what the vault now uses everywhere liquidation eligibility or reward is computed (`liquidate`, `liquidateWithFlashMint`, `liquidateFromStabilityPool`, `clearBadDebt`'s underwater check).

**Poke:** Anyone can advance the oracle state machine by calling `poke()`. Rate-limited to once per 30 minutes.

**Dead oracle override:** If the oracle is dead for 7+ days, emergency repay and withdraw are enabled regardless of price data.

---

## The Stability Pool

New in V9. Standard Liquity-style Product-Sum accounting (`P`/`S`/`scale`/`epoch`), so liquidations can be absorbed **atomically** by pre-deposited pSunDAI instead of depending on a keeper holding capital and reselling seized collateral into PulseChain's own (thin) DEX liquidity — closing the dependency that made the original liquidation design fragile at any meaningful scale.

**How it works:**
1. Anyone deposits pSunDAI via `provideToStabilityPool(amount)`.
2. When a vault drops below 110% CR, anyone can call `liquidateFromStabilityPool(user)` — fully permissionless, and the caller needs **no capital of their own**. The function computes `debtToOffset = min(vault.debt, totalStabilityDeposits)`, burns that much pSunDAI directly from the pool's own held balance, and credits the vault's collateral (principal + the same 2-5% Dutch-auction bonus the keeper path uses) to the pool for depositors — minus a small flat tip (`LIQUIDATION_CALLER_TIP_BPS`, 0.5%) paid to whoever triggered it, as gas compensation.
3. Depositors' balances compound down (on a loss) or up (on stability-fee yield — see next section) via the shared `P` multiplier, so a claim is always correct regardless of when a depositor joined, with no need to iterate over depositors on-chain.
4. If the pool can't fully cover a vault's debt, it absorbs what it can and the remainder stays open for the ordinary keeper `liquidate()`/`liquidateWithFlashMint()` path, exactly as before.

**Stability Pool functions:**
| Function | What it does |
|----------|-------------|
| `provideToStabilityPool(amount)` | Deposit pSunDAI into the pool. Requires prior ERC20 approval. Harvests any pending collateral gain first. |
| `withdrawFromStabilityPool(amount)` | Withdraw up to your compounded balance. Harvests any pending gain first. |
| `claimCollateralGain()` | Claim your pending collateral gain without depositing/withdrawing. |
| `liquidateFromStabilityPool(user)` | Permissionless — trigger SP-absorbed liquidation on an eligible vault. |
| `getCompoundedStabilityDeposit(address)` | View — your current principal, after all gains/losses since you joined. |
| `getDepositorCollateralGain(address)` | View — your currently claimable WPLS. |
| `getStabilityPoolStats()` | View — `(totalDeposits, totalCollateralHeld, currentP, scale, epoch)`. |

**On a full pool wipeout** (a liquidation whose debt exactly matches or exceeds total deposits): `currentEpoch` increments and `P` resets to `1e18`. Depositors present before the wipeout retain their claim to any collateral gain from the wipeout event itself, but their principal correctly zeroes out; new depositors after a wipeout start in the new epoch, fully isolated from the exhausted one.

This is the single most novel piece of new logic in the contract set — the standard published Liquity algorithm, not something invented from scratch, but still the highest-scrutiny area if this protocol is ever professionally audited. Foundry-tested extensively (see [Compiling](#compiling)), including forced full-wipeout and scale-rollover edge cases.

---

## How to Use

### Auto Mode (Recommended)
1. Connect a wallet on PulseChain (chain ID 369)
2. Enter a PLS amount in the Auto tab
3. Click **1-Click Auto Borrow** — deposits PLS and mints pSunDAI at 155% CR in one transaction

**Note:** the deposit always succeeds even if the mint doesn't. If the dynamic debt ceiling or your vault's cap is reached at the moment you transact, the contract silently skips the mint while the deposit still lands — the UI checks the transaction receipt and tells you which actually happened, rather than assuming success.

### Manual Flow
**Deposit PLS** → lock native PLS as collateral (auto-wrapped to WPLS internally). Or deposit WPLS directly after approval.

**Mint pSunDAI** → borrow USD-equivalent against your PLS. Minimum 150% CR after mint, and bounded by your vault's cap.
```
CR = (WPLS Collateral × PLS Price) ÷ pSunDAI Debt × 100%
```

**Repay** → burn pSunDAI to reduce debt. No approval needed — the vault has direct privileged burn rights.

**Withdraw** → pull PLS back (as native PLS via `withdrawPLS()` or as WPLS via `withdrawWPLS()`). CR must stay ≥ 150% after withdrawal. 5-minute cooldown after deposit.

**Full Exit** → Repay All & Withdraw — single transaction, closes position entirely.

### Earning yield (new in V9)
You don't need an open vault to participate in the Stability Pool. Acquire pSunDAI (mint against your own collateral, or receive/buy it), then `provideToStabilityPool(amount)`. You'll earn a share of the stability fee continuously (whether or not any liquidation happens) plus a share of any liquidation bonuses while your deposit is in the pool.

---

## Vault Health Zones

| CR | Status | Description |
|----|--------|--------------|
| Above 150% | Safe | Can mint more, can withdraw. Immune to liquidation. |
| 110–150% | At risk | Cannot mint more. Add collateral. |
| Below 110% | Liquidatable | Absorbed by the Stability Pool if funded, otherwise keepers repay debt and claim WPLS + bonus. |

**Recommended target:** 175%+ CR to absorb PLS price swings comfortably.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable — via the [Vault Dashboard](liquidations.html).

**Process (V9, Stability-Pool-first):**
1. Open Vault Dashboard → Liquidate tab
2. Scan all vaults — finds those below 110% CR
3. If the Stability Pool has funds, click **Liquidate via Stability Pool** — no pSunDAI required from you, the pool covers it and pays you a small tip
4. If the pool is empty or only partially covers the debt, fall back to the manual **Liquidate** action — enter pSunDAI to repay (minimum 20% of vault debt), confirm, and the vault burns your pSunDAI and sends you proportional PLS + bonus

**Bonus:** starts at **2%** when the auction clock begins, grows to **5%** at the 3-hour mark — same curve for both the Stability Pool path and the manual keeper path. Call `markUndercollateralized(addr)` to start the clock without liquidating.

**No cooldown:** any number of liquidation calls can land on the same vault back-to-back — multiple liquidators (or the pool, plus keepers for the remainder) can clear a large position in parallel instead of waiting on a per-vault clock.

**Fully underwater vaults (collateral < 100% of debt):** if `clearBadDebt(address, repayAmount)` — **V9 change:** this used to seize 100% of the vault's collateral for free (the H1 exploit). It now requires the caller to actually repay `repayAmount` pSunDAI (up to the full debt) and pays out collateral **strictly pro-rata**, with no bonus. Since the vault is underwater by definition, a caller can never profit from this — it's a voluntary, loss-taking cleanup action, not a reward.

---

## Stability Fee, Surplus Buffer, and Stability Pool Yield

**0.5% annual stability fee** accrues continuously to vault debt, same rate as V8. What happens to that fee is different in V9:

```
V8: stability fee → surplusBuffer (inert accounting counter, no beneficiary)
V9: stability fee → Stability Pool depositors, IF the pool has deposits (real, auto-compounding yield)
    stability fee → surplusBuffer, IF the pool is empty (fallback, same as V8's only behavior)
```

The fee mints directly into the pool and grows the shared `P` multiplier upward — the same multiplicative mechanism that shrinks `P` on a liquidation loss, just inverted. Every depositor's `getCompoundedStabilityDeposit()` reflects this automatically and proportionally; there's no separate claim step for the fee-yield portion, it compounds into your principal. Flash-mint liquidation fees (0.2% of repaid amount) are routed the same way.

```
surplusBuffer (V9): fallback destination for fees when the pool is empty, plus the
                     interest-accrual dust-clearing path
Bad liquidation:     absorbed by the Stability Pool's own loss-accounting (P shrinks),
                     or — for the rare fully-underwater case with an empty pool —
                     left as an open, visible position until someone voluntarily
                     calls clearBadDebt() and pays down the shortfall themselves
reconcile()          nets surplusBuffer against badDebtAccumulated automatically
                     on every fee accrual
```

---

## Debt Ceiling

`DEBT_CEILING = 10,000,000,000e18` (10 billion pSunDAI) — an immutable outer sanity bound picked deliberately high so it never realistically binds. The number that actually constrains minting day to day is `effectiveDebtCeiling() = min(DEBT_CEILING, oracle.maxSafeDebt())`, and `maxSafeDebt()` is **dynamic** — it re-reads live PulseX pool reserves every call and scales automatically with real liquidity, growing (or shrinking) with zero contract changes ever required.

At deploy time (2026-07-05), real combined stable-side depth across the 5 oracle pools was ~$1.06M, giving `maxSafeDebt() ≈ $5.3M` — that's the honest day-one capacity. This is expected to grow as PulseChain's real DEX liquidity grows; a genuine, sustained PLS price appreciation by a factor `F` mechanically grows pool depth by roughly `√F` via ordinary AMM arbitrage dynamics (no new liquidity providers required), so real capacity scales non-linearly with market conditions rather than needing a redeploy to "unlock" higher numbers.

---

## Emergency Functions

| Function | When Available | What it Does |
|----------|---------------|-------------|
| `emergencyUnlock()` | Zero debt + last deposit >30 days | Recover PLS regardless of oracle |
| `emergencyRepay(amount)` | Oracle dead >7 days | Repay debt without oracle price |
| `emergencyWithdrawPLS(amount)` | Oracle dead >7 days + zero debt | Withdraw PLS without oracle |

These exist so users can always exit their own position, even if the oracle permanently fails.

---

## Protocol Tools

Public functions callable by any wallet. No economic cost beyond gas, except the flash-mint path (requires a contract caller) and the manual keeper `liquidate()` path (requires pre-held pSunDAI).

| Function | What it Does |
|----------|--------------|
| `reconcile()` | Net surplus buffer against bad debt |
| `oracle.poke()` | Advance oracle TWAP + liquidity-sample state machine (30 min cooldown) |
| `markUndercollateralized(addr)` | Start the 3-hour liquidation bonus clock without liquidating |
| `liquidateFromStabilityPool(user)` | **New in V9.** Permissionless, no capital required — SP-absorbed liquidation |
| `liquidate(user, repayAmount)` | Standard liquidation — caller must already hold the pSunDAI being repaid |
| `liquidateWithFlashMint(user, repayAmount, data)` | Liquidation without pre-holding pSunDAI — caller must be a contract implementing `IFlashLiquidationReceiver` |
| `clearBadDebt(addr, repayAmount)` | **Changed in V9.** Voluntarily unwind a fully-underwater vault at strict pro-rata, no bonus — see [Liquidations](#liquidations) |
| `settleDebt(amount)` | Burn your own pSunDAI to cancel accumulated bad debt |
| `provideToStabilityPool(amount)` / `withdrawFromStabilityPool(amount)` / `claimCollateralGain()` | **New in V9.** Stability Pool participation |

---

## System Invariants

```
I1  — Min CR:              150% required to mint or maintain position
I2  — Liquidation:         Vaults below 110% CR can be liquidated
I3  — No redemption:       pSunDAI does not include a redemption mechanism
I4  — Oracle resilience:   Stale oracle blocks minting, never blocks deposit/repay
I5  — Immutability:        No admin, no pause, no upgrade after setVault()
I6  — Liveness:            7-day oracle failure enables emergency exit paths
I7  — Fee accounting:      Stability/flash-mint fees always go somewhere productive —
                            Stability Pool yield when it has deposits, surplusBuffer
                            fallback otherwise — never lost or stranded
I8  — Privileged burn:     Vault burns from msg.sender directly via onlyVault
                            token.burn(); no approve needed
I9  — Dual-track:          Flash crashes never trigger spot liquidation; real
                            crashes do — and even when triggered, spot is clamped
                            to within 15% of TWAP (V9, closes the H2 exploit)
I10 — No free extraction:  clearBadDebt() pays out strictly pro-rata to actual
                            repayment — never more value than was paid in (V9,
                            closes the H1 exploit; V8 gave 100% away for free)
I11 — Effective ceiling:   Total supply bounded by min(immutable DEBT_CEILING,
                            oracle.maxSafeDebt()) — the dynamic side moves with
                            real pool liquidity, the static side never can
I12 — Bonus growing:       Liquidation bonus starts at min (2%), grows to
                            max (5%) over 3 hours — same curve for Stability
                            Pool and keeper liquidation paths
I13 — Per-vault cap:       No single vault's debt may exceed
                            oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP
I14 — Liquidity floor is
      monotonic-safe:      maxSafeDebt() can never be inflated by a liquidity
                            spike sustained less than the 24h rolling window; a
                            genuine liquidity drop is reflected immediately
I15 — No liquidation
      cooldown:             Any number of liquidation calls may land on the same
                            vault in the same block
I16 — Flash-mint atomicity: liquidateWithFlashMint mints no tokens at any point;
                            if repayment fails, the entire transaction — including
                            the collateral transfer — reverts
I17 — SP conservation:     Sum of all depositors' compounded balances always
                            equals totalStabilityDeposits; sum of claimable
                            collateral gains always equals stabilityPoolCollateral
                            (V9, new — Foundry-verified via the Product-Sum
                            accounting's error-carry terms)
I18 — Pool isolation:      A Stability Pool depositor's snapshot from before an
                            epoch-ending full wipeout cannot claim principal from
                            or interfere with deposits made after it (V9, new)
```

---

## Deployed Contracts

**PulseChain (Chain ID: 369)** — verified on Sourcify (exact match, creation + runtime bytecode)

| Contract | Address |
|----------|---------|
| **pSunDAI Token** | `0x1b13cFddab761372cBBF815502E38b4e3613dDF9` |
| **Vault V9** | `0x23669aeeaE9Fe50e9453ABB556Ff75Eae3EEB931` |
| **Oracle V9** | `0xaaa9e184BA6Ef908c464A2c9e91B990bEAb7faB7` |

**Required external addresses (PulseChain mainnet) — same pools V8 used:**

| Token | Address |
|-------|---------|
| WPLS | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |
| DAI | `0xefD766cCb38EaF1dfd701853BFCe31359239F305` |
| USDC | `0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07` |
| USDT | `0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f` |

| PulseX Pair | Address |
|-------------|---------|
| WPLS/DAI v1 | `0xE56043671df55dE5CDf8459710433C10324DE0aE` |
| WPLS/DAI v2 | `0x146E1f1e060e5b5016Db0D118D2C5a11A240ae32` |
| WPLS/USDC v1 | `0x6753560538ECa67617A9Ce605178F788bE7E524E` |
| WPLS/USDC v2 | `0x8eBe62D5e9D26b637673d91f56900233d6A4910d` |
| WPLS/USDT | `0x322Df7921F28F1146Cdf62aFdaC0D6bC0Ab80711` |

---

## Compiling

**Compiler:** solc `0.8.20`, `evmVersion: shanghai`. **OpenZeppelin:** v5.0.2 (plain `@openzeppelin/contracts/...` imports). `pSunDAIVault_ASA_v9.sol` requires `via_ir = true` to compile — a Foundry codegen setting that resolves a stack-too-deep error, does not change the target EVM version or on-chain behavior. The vault compiles to 22,284/24,576 bytes (EIP-170 limit) — comfortable today, but with only ~9% margin left for any future addition.

Source is in `contracts/` in this folder — the exact code deployed at the addresses above, matching what's verified on Sourcify.

**Foundry:**
```
forge init && forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
# copy contracts/ into your src/, set solc_version=0.8.20, evm_version="shanghai", via_ir=true
forge build
```

A full Foundry test project (mocks, harness for direct Stability Pool unit tests, and the deploy script actually used) lives in `test-foundry/` — 27 tests, all passing, including exploit-regression tests proving the H1/H2 findings above no longer reproduce against this code.

---

## Deploy Order

```
1. Deploy pSunDAI_ASA (token)
   → Records deployer address

2. Deploy pSunDAIoraclePLSXHybrid_v9
   args: pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT,
         wpls, dai, usdc, usdt
   → bootstraps lastPrice from spot median at deploy; seeds the first
     rolling liquidity sample from current pool state

3. Deploy pSunDAIVault_ASA_v9
   args: wpls, psundai_address, oracle_address, debtCeiling
   → sets lastOraclePrice from oracle.peekPriceView() at deploy

4. oracle.setVault(vault_address)
   → permanent latch, one-time call, enables getPriceWithTimestamp()

5. token.setVault(vault_address)
   → permanent latch, one-time call, no admin after this

── system is now fully autonomous ──
```

Contract addresses are live on PulseChain — already set in both HTML files.

**A note on the actual deploy:** the broadcast for this deployment hit a client-side timeout partway through (PulseChain confirmation latency across sequential transactions), landing 4 of 5 transactions before being interrupted. This was caught by independently checking on-chain state (`cast call vault()`/`vaultSet()`/`immutableSet()`) rather than trusting the script's own "success" log — the 5th transaction (`token.setVault`) was sent separately to complete the linkage, safely, since that function is one-time-only and reverts if already set. If you're redeploying this yourself: verify each `setVault()` call landed independently before considering the deploy complete, regardless of what your tooling reports.

---

## Security Model

**No admin keys.** `setVault()` is the only privileged function on both token and oracle — becomes permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons.

**Direct privileged burn.** The pSunDAI token exposes `burn(address from, uint256 amount)` gated by `onlyVault`. No ERC20 `approve()` is required before repaying or liquidating.

**Oracle manipulation resistance.** 5-pool liquidity-weighted median (now requiring at least 3 valid pools), confirmation periods for large moves, a rolling cumulative-drift check against chained small moves, a rolling-minimum liquidity floor against flash-liquidity cap inflation, and (new in V9) a hard 15% clamp on the price used for liquidation even once the spot arm activates.

**No free value extraction.** (New in V9.) Every path that moves collateral out of a vault — keeper liquidation, Stability Pool absorption, and the fully-underwater `clearBadDebt` path — now requires the recipient to have paid at least the value they receive, closing the exploit that existed in V8.

**What the contracts cannot do:**
- Mint pSunDAI to arbitrary addresses
- Pause or freeze any function
- Change CR requirements, liquidation ratios, or fee structures
- Access or redirect user collateral outside of vault operations
- Raise `DEBT_CEILING` past its deploy-time value, regardless of how much oracle liquidity grows

**Audit status.** V9 is Foundry-tested (27/27 passing, including targeted exploit-regression and Stability Pool edge-case tests) and has been reviewed by the author across multiple passes, but **has not received a professional third-party audit.** The Stability Pool's Product-Sum accounting is the single most novel piece of logic in this contract set — it is the standard published Liquity algorithm, not something invented from scratch, but it is still the area most worth independent audit attention if and when this protocol seeks one. Two real implementation bugs (both in this exact mechanism) were caught during the author's own test-writing process before deployment — a data point in favor of testing over confidence in a from-memory formula, not a claim that testing found everything.

---

## Frontend Files

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, Stability Pool, oracle status, system state |
| `liquidations.html` | Dashboard — scan all vaults, liquidate (Stability Pool first, keeper fallback), inspect, flash-mint liquidation reference |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `manifest.json` | PWA manifest |
| `sw.js` | Service worker — cache-first, offline-friendly on IPFS |
| `sundailogo.png`, `favicon.svg` | Protocol branding |
| `contracts/pSunDAI_ASA_Token_v9.sol` | Token source (near-unchanged from V7/V8) |
| `contracts/pSunDAIVault_ASA_v9.sol` | Vault source |
| `contracts/pSunDAI_Oracle_Hybrid_v9.sol` | Oracle source |
| `test-foundry/` | Foundry test project — mocks, harness, deploy script, 27 passing tests |

Both HTML files have contract ABIs inlined directly — no external fetch, no build step. All contract addresses are already set.

---

*pSunDAI V9 is experimental software. No professional third-party audit has been performed. It passed an internal Foundry test suite (27 tests, including exploit-regression tests against the specific V8 findings this version fixes) and multiple author review passes, which is not a substitute for professional review. Use at your own risk.*

**License: MIT**
