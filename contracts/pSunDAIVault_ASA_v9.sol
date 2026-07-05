// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║              pSunDAIVault ASA v9 — Stability Pool Hardening          ║
 * ║                                                                      ║
 * ║   Carries forward all v8 logic unchanged (interest accrual + surplus ║
 * ║   buffer, dynamic ceiling / per-vault cap, emergency exits, vault    ║
 * ║   enumeration, no liquidation cooldown, flash-mint-free liquidation).║
 * ║   v9 responds to an external review that found two exploitable       ║
 * ║   flaws and one structural gap in v8:                                ║
 * ║                                                                      ║
 * ║   1. clearBadDebt() used to seize 100% of a vault's collateral for   ║
 * ║      free once collateral value dipped under 100% of debt — and     ║
 * ║      that check read the manipulable spot price, so an attacker     ║
 * ║      could suppress spot to trigger it on a healthy vault. v9        ║
 * ║      requires the caller to actually repay pSunDAI and pays out      ║
 * ║      collateral strictly pro-rata with no bonus, so the position is  ║
 * ║      still a real (voluntary) loss to close, never a profit.         ║
 * ║                                                                      ║
 * ║   2. Liquidation eligibility/reward now reads oracle.getLiquidation- ║
 * ║      Price(), which hard-clamps spot to within 15% of TWAP — closing ║
 * ║      the previously-unbounded manipulation-profit window on the spot ║
 * ║      liquidation arm.                                                ║
 * ║                                                                      ║
 * ║   3. STABILITY POOL (new). Depositors pre-supply pSunDAI that        ║
 * ║      absorbs liquidations atomically via liquidateFromStabilityPool  ║
 * ║      — no DEX resale needed, no dependency on thin PulseChain        ║
 * ║      liquidity for liquidation throughput. Standard Liquity-style    ║
 * ║      Product-Sum accounting (P/S/scale/epoch) so each depositor's    ║
 * ║      share compounds down correctly across any number of offsets,    ║
 * ║      including a full pool wipeout. The existing keeper liquidate()  ║
 * ║      and liquidateWithFlashMint() paths remain, unchanged, for       ║
 * ║      whatever the pool can't cover.                                  ║
 * ║                                                                      ║
 * ║   4. STABILITY POOL YIELD (new). The stability fee and flash-mint    ║
 * ║      fee, which used to just inflate an inert surplusBuffer counter  ║
 * ║      with no beneficiary, now mint directly into the Stability Pool  ║
 * ║      as auto-compounding yield (see _distributeFee) whenever the     ║
 * ║      pool has depositors — real, continuous incentive to keep it     ║
 * ║      funded, not just an opportunistic payout during liquidations.   ║
 * ║      Falls back to surplusBuffer only when the pool is empty.        ║
 * ║                                                                      ║
 * ║   ── WHAT DIDN'T CHANGE ────────────────────────────────────────     ║
 * ║   - COLLATERAL_RATIO 150% / LIQUIDATION_RATIO 110%                   ║
 * ║   - Stability fee 0.5% APY, Dutch auction bonus 2-5% over 3h         ║
 * ║   - No admin keys, no upgradeability                                 ║
 * ║   - Dynamic ceiling / per-vault cap architecture (now inheriting     ║
 * ║     the oracle's tighter 5x capacity multiplier)                     ║
 * ║   - Emergency exits, vault enumeration, no liquidation cooldown      ║
 * ║   - liquidate(address,uint256) and liquidateWithFlashMint() bodies   ║
 * ║                                                                      ║
 * ║   Dev: ELITE TEAM6 | https://www.sundaitoken.com                     ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./pSunDAI_ASA_Token_v9.sol";
import "./pSunDAI_Oracle_Hybrid_v9.sol";

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @notice Implemented by the liquidator's own contract to receive the collateral
///         and settle liquidateWithFlashMint() in the same transaction. The vault
///         calls back into msg.sender (the caller of liquidateWithFlashMint) — not
///         into an arbitrary target — specifically so that any swap the receiver
///         performs is correctly attributed to the receiver's own address (its own
///         approvals, its own balance), not to the vault.
interface IFlashLiquidationReceiver {
    function onFlashLiquidation(
        address user,
        uint256 collateralReceived,
        uint256 amountOwed,
        bytes calldata data
    ) external;
}

contract pSunDAIVault_ASA_v9 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ── Immutables ───────────────────────────────────────────────────────────
    IERC20 public immutable wpls;
    pSunDAI_ASA public immutable psundai;
    pSunDAIoraclePLSXHybrid_v9 public immutable oracle;
    uint256 public immutable DEBT_CEILING;

    string public constant VERSION = "pSunDAIVault_ASA_v9";

    // ── Protocol parameters ──────────────────────────────────────────────────
    uint256 public constant COLLATERAL_RATIO     = 150;
    uint256 public constant AUTO_MINT_RATIO      = 155;
    uint256 public constant LIQUIDATION_RATIO    = 110;
    uint256 public constant MIN_ACTION_AMOUNT    = 1e14;
    uint256 public constant WITHDRAW_COOLDOWN    = 300;
    uint256 public constant MIN_LIQUIDATION_BPS  = 2000;   // 20% min partial liquidation
    uint256 public constant MIN_BONUS_BPS        = 200;    // 2% starting bonus
    uint256 public constant MAX_BONUS_BPS        = 500;    // 5% max after 3h
    uint256 public constant AUCTION_TIME         = 3 hours;
    uint256 public constant MIN_SYSTEM_HEALTH    = 130;
    uint256 public constant STABILITY_FEE_BPS    = 50;     // 0.5% APY
    uint256 public constant SECONDS_PER_YEAR     = 31_536_000;
    uint256 public constant MAX_VOLATILITY_BPS   = 1000;   // 10% vault-level TWAP clamp
    uint256 public constant ORACLE_DEAD_THRESHOLD = 7 days;

    // ── Dynamic-capacity parameters ───────────────────────────────────────────
    // A single vault may hold at most oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP —
    // forces natural diversification instead of allowing one position to
    // concentrate a large share of system debt in a single liquidation target.
    uint256 public constant MAX_VAULTS_AT_CAP = 10;
    // Premium on liquidateWithFlashMint, routed into surplusBuffer.
    uint256 public constant FLASH_FEE_BPS = 20; // 0.2%

    // ── v9: Stability Pool parameters ─────────────────────────────────────────
    // Flat tip (as a fraction of the repaid debt's collateral value) paid to
    // whoever triggers liquidateFromStabilityPool(), as gas compensation — the
    // rest of the liquidation reward (principal + Dutch-auction bonus) goes to
    // the pool for depositors, since it's their capital doing the absorbing.
    uint256 public constant LIQUIDATION_CALLER_TIP_BPS = 50; // 0.5%
    uint256 public constant DECIMAL_PRECISION = 1e18;
    uint256 public constant SCALE_FACTOR      = 1e9;

    // ── Vault struct ─────────────────────────────────────────────────────────
    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        uint256 lastDebtAccrual;
        uint256 undercollateralizedSince;
    }

    // ── System state ─────────────────────────────────────────────────────────
    mapping(address => Vault) public vaults;
    uint256 public totalCollateral;
    uint256 public totalDebt;
    uint256 public lastOraclePrice;
    uint256 public lastOracleUpdateTime;

    // ── Surplus buffer and bad debt ───────────────────────────────────────────
    // surplusBuffer: fallback destination for stability/flash-mint fees when
    //   the Stability Pool is empty (nobody to pay yield to yet), plus the
    //   interest-accrual dust-clearing path (see _accrueInterest). Whenever
    //   the Stability Pool is non-empty, fees are minted directly to it
    //   instead (see _distributeFee) — real yield for depositors, funded by
    //   the same borrower debt growth that used to just inflate this counter
    //   with nowhere for it to go.
    // badDebtAccumulated: uncovered debt from the interest-accrual dust-clearing
    //   path (see _accrueInterest). v9's clearBadDebt no longer feeds this — a
    //   caller who unwinds a fully-underwater vault now pays pro-rata, so any
    //   shortfall is absorbed by that caller directly rather than becoming
    //   protocol-level bad debt; see clearBadDebt's docstring.
    uint256 public surplusBuffer;
    uint256 public badDebtAccumulated;

    // ── v9: Stability Pool state ──────────────────────────────────────────────
    // Standard Liquity-style Product-Sum accounting. `P` starts at
    // DECIMAL_PRECISION and shrinks multiplicatively every time the pool
    // absorbs a loss; each depositor's compounded balance is their initial
    // deposit scaled by how much P has moved since their last snapshot. `S`
    // (per epoch/scale) accumulates the collateral-gain rate so each
    // depositor's claimable gain is computed from the S delta since their
    // snapshot. `currentEpoch` increments (and P resets to DECIMAL_PRECISION)
    // on a full 100% pool wipeout; `currentScale` increments whenever P would
    // otherwise lose too much precision to remain useful.
    struct StabilitySnapshot {
        uint256 P;
        uint256 S;
        uint128 scale;
        uint128 epoch;
    }

    uint256 public totalStabilityDeposits;
    uint256 public stabilityPoolCollateral; // WPLS held by the pool, claimable pro-rata by depositors
    mapping(address => uint256) public stabilityDeposits; // raw deposit value as of depositor's last snapshot
    mapping(address => StabilitySnapshot) public depositSnapshots;

    uint256 public P = DECIMAL_PRECISION;
    uint128 public currentScale;
    uint128 public currentEpoch;
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToSum;

    uint256 internal lastCollateralError_Offset;
    uint256 internal lastDebtLossError_Offset;
    uint256 internal lastFeeGainError_Offset;

    // ── Vault enumeration ─────────────────────────────────────────────────────
    address[] public vaultOwners;
    mapping(address => bool) public hasVault;

    // ── Events ───────────────────────────────────────────────────────────────
    event Deposit(address indexed user, uint256 amount, uint256 ratio);
    event Withdraw(address indexed user, uint256 amount, uint256 ratio);
    event Mint(address indexed user, uint256 amount, uint256 ratio);
    event Repay(address indexed user, uint256 amount, uint256 ratio);
    event Liquidation(address indexed user, uint256 repayAmount, address indexed liquidator, uint256 reward, uint256 ratio, bool spotPrice);
    event BadDebtCleared(address indexed user, uint256 collateralReturned, uint256 debtRepaid, address indexed caller);
    event DebtSettled(uint256 amount, address indexed settler);
    event SurplusReconciled(uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event EmergencyRepay(address indexed user, uint256 amount);
    event EmergencyWithdrawOracleDead(address indexed user, uint256 amount);
    event VaultRegistered(address indexed user);
    event VaultMarkedUndercollateralized(address indexed user, uint256 timestamp);
    event OracleFallbackUsed(uint256 price);
    event DebtCeilingReached(uint256 totalDebt, uint256 ceiling);
    event StabilityDeposit(address indexed depositor, uint256 amount);
    event StabilityWithdraw(address indexed depositor, uint256 amount);
    event CollateralGainWithdrawn(address indexed depositor, uint256 amount);
    event StabilityPoolOffset(uint256 debtOffset, uint256 collateralAdded);
    event StabilityPoolEmptied(uint128 newEpoch);
    event StabilityPoolFeeDistributed(uint256 feeAmount);
    event LiquidatedFromStabilityPool(address indexed user, uint256 debtOffset, uint256 collateralToPool, uint256 callerTip, address indexed caller);

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _wpls,
        address _psundai,
        address _oracle,
        uint256 _debtCeiling
    ) {
        require(_wpls != address(0) && _psundai != address(0) && _oracle != address(0), "Zero address");
        require(_debtCeiling > 0, "Invalid ceiling");

        wpls         = IERC20(_wpls);
        psundai      = pSunDAI_ASA(_psundai);
        oracle       = pSunDAIoraclePLSXHybrid_v9(_oracle);
        DEBT_CEILING = _debtCeiling;

        (uint256 initialPrice,) = pSunDAIoraclePLSXHybrid_v9(_oracle).peekPriceView();
        require(initialPrice > 0, "Oracle not ready");
        lastOraclePrice      = initialPrice;
        lastOracleUpdateTime = block.timestamp;
    }

    // ── ETH sender ───────────────────────────────────────────────────────────
    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // ── Vault registration ────────────────────────────────────────────────────
    function _registerVault(address user) internal {
        if (!hasVault[user]) {
            hasVault[user] = true;
            vaultOwners.push(user);
            emit VaultRegistered(user);
        }
    }

    // ── Dynamic capacity ──────────────────────────────────────────────────────

    /// @notice Effective debt ceiling actually enforced: the lesser of the
    ///         immutable outer bound and the oracle's real-time, liquidity-derived
    ///         safe capacity. Moves automatically as pool depth changes.
    function _effectiveDebtCeiling() internal view returns (uint256) {
        uint256 dynamicCap = oracle.maxSafeDebt();
        return dynamicCap < DEBT_CEILING ? dynamicCap : DEBT_CEILING;
    }

    function effectiveDebtCeiling() external view returns (uint256) {
        return _effectiveDebtCeiling();
    }

    /// @notice Maximum debt a single vault may hold, derived from the same
    ///         liquidity signal as the effective ceiling.
    function _vaultCap() internal view returns (uint256) {
        return oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP;
    }

    function vaultCap() external view returns (uint256) {
        return _vaultCap();
    }

    // ── Price helpers ─────────────────────────────────────────────────────────

    /// @notice Get conservative TWAP price, advance oracle state.
    ///         Used for: minting, withdrawal safety checks, interest accrual.
    function _safeMintPrice() internal returns (uint256 p) {
        uint256 ts;
        bool oracleAdvanced;

        try oracle.getPriceWithTimestamp() returns (uint256 _p, uint256 _ts) {
            p  = _p;
            ts = _ts;
            oracleAdvanced = true;
        } catch {
            (p, ts) = oracle.peekPriceView();
            emit OracleFallbackUsed(p > 0 ? p : lastOraclePrice);
        }

        if (p == 0) {
            emit OracleFallbackUsed(lastOraclePrice);
            return lastOraclePrice > 0 ? lastOraclePrice : 1e18;
        }

        if (lastOraclePrice > 0) {
            uint256 diff = p > lastOraclePrice ? p - lastOraclePrice : lastOraclePrice - p;
            uint256 volatilityBps = (diff * 10_000) / lastOraclePrice;

            if (volatilityBps > MAX_VOLATILITY_BPS) {
                (,,,bool inConfirmation,,,,) = oracle.getPriceStatus();

                if (inConfirmation) {
                    lastOraclePrice = p;
                    if (oracleAdvanced) lastOracleUpdateTime = ts;
                } else {
                    uint256 cooldown   = p < lastOraclePrice ? 4 hours : 1 hours;
                    uint256 lowerBound = (lastOraclePrice * 9000) / 10000;
                    uint256 upperBound = (lastOraclePrice * 11000) / 10000;

                    if (p >= lowerBound && p <= upperBound) {
                        lastOraclePrice = p;
                        if (oracleAdvanced) lastOracleUpdateTime = ts;
                    } else if (block.timestamp - lastOracleUpdateTime >= cooldown) {
                        lastOraclePrice = p;
                        if (oracleAdvanced) lastOracleUpdateTime = ts;
                    } else {
                        emit OracleFallbackUsed(lastOraclePrice);
                        p = lastOraclePrice;
                    }
                }
            } else {
                lastOraclePrice = p;
                if (oracleAdvanced) lastOracleUpdateTime = ts;
            }
        } else {
            lastOraclePrice = p;
            if (oracleAdvanced) lastOracleUpdateTime = ts;
        }

        return p;
    }

    /// @notice v9: price to use for liquidation eligibility and reward calculation.
    ///         Uses oracle.getLiquidationPrice(), which returns the spot median
    ///         hard-clamped to within 15% of TWAP once the spot arm has confirmed
    ///         a sustained divergence, or the TWAP itself otherwise. Advances
    ///         oracle TWAP state on the non-spot path (same as v8).
    function _liquidationPrice() internal returns (uint256 price, bool isSpot) {
        (uint256 p, bool spot) = oracle.getLiquidationPrice();
        if (spot && p > 0) return (p, true);
        return (_safeMintPrice(), false);
    }

    /// @notice View version of liquidation price for read-only checks.
    function _liquidationPriceView() internal view returns (uint256 price, bool isSpot) {
        (uint256 p, bool spot) = oracle.getLiquidationPrice();
        if (spot && p > 0) return (p, true);
        (uint256 tp,) = oracle.peekPriceView();
        return (tp > 0 ? tp : lastOraclePrice, false);
    }

    // ── Interest accrual with surplus buffer ──────────────────────────────────

    function _touch(address user) internal {
        Vault storage v = vaults[user];
        if (v.debt > 0) _accrueInterest(v);
    }

    function _accrueInterest(Vault storage v) internal {
        if (v.debt == 0) { v.lastDebtAccrual = block.timestamp; return; }
        uint256 elapsed = block.timestamp - v.lastDebtAccrual;
        if (elapsed == 0) return;

        uint256 fee = (v.debt * STABILITY_FEE_BPS * elapsed) / (SECONDS_PER_YEAR * 10_000);
        if (fee == 0 && elapsed > 0) fee = 1;

        v.debt    += fee;
        totalDebt += fee;
        _distributeFee(fee);

        v.lastDebtAccrual = block.timestamp;

        // Dust clearing: remove micro-debts to prevent permanent tiny-debt state.
        // surplusBuffer may or may not have just been fed by this specific fee
        // (it's only the fallback when the Stability Pool is empty) - at this
        // sub-1e12-wei scale that's immaterial, so this just forgives what it
        // can from whatever balance exists.
        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        _reconcile();
    }

    /// @notice Apply accumulated surplus against outstanding bad debt.
    function _reconcile() internal {
        if (surplusBuffer > 0 && badDebtAccumulated > 0) {
            uint256 applied = surplusBuffer < badDebtAccumulated
                ? surplusBuffer
                : badDebtAccumulated;
            surplusBuffer      -= applied;
            badDebtAccumulated -= applied;
            emit SurplusReconciled(applied);
        }
    }

    // ── System state views ────────────────────────────────────────────────────

    function isUXSafe() public view returns (bool) {
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        return p > 0 && block.timestamp - ts <= 1 hours && systemHealth() >= MIN_SYSTEM_HEALTH;
    }

    function isOracleDead() public view returns (bool) {
        return oracle.isStale(ORACLE_DEAD_THRESHOLD);
    }

    function systemHealth() public view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPriceView();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (totalCollateral * price * 100) / (totalDebt * 1e18);
    }

    /// @notice Net system solvency: positive = surplus equity, negative = bad debt outstanding.
    function systemEquity() external view returns (int256) {
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    function _collateralRatio(address user) internal view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPriceView();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (v.collateral * price * 100) / (v.debt * 1e18);
    }

    function _checkSafe(uint256 col, uint256 debt, uint256 price) internal pure returns (bool) {
        if (debt == 0) return true;
        return col * price * 100 >= debt * COLLATERAL_RATIO * 1e18;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────
    function depositPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        wpls.safeTransferFrom(msg.sender, address(this), amount);
        _addCollateral(msg.sender, amount);
    }

    function _addCollateral(address user, uint256 amount) internal {
        _registerVault(user);
        Vault storage v = vaults[user];
        v.collateral     += amount;
        v.lastDepositTime = block.timestamp;
        totalCollateral  += amount;
        emit Deposit(user, amount, _collateralRatio(user));
    }

    // ── One-click deposit + mint ──────────────────────────────────────────────

    /// @notice Deposit PLS and auto-mint pSunDAI at 155% collateral ratio.
    function depositAndAutoMintPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);

        uint256 price      = _safeMintPrice();
        uint256 valueUSD   = (msg.value * price) / 1e18;
        uint256 mintAmount = (valueUSD * 100) / AUTO_MINT_RATIO;

        uint256 ceiling = _effectiveDebtCeiling();
        Vault storage v = vaults[msg.sender];
        uint256 cap     = _vaultCap();

        if (mintAmount > 0 && totalDebt + mintAmount <= ceiling && v.debt + mintAmount <= cap) {
            if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
            v.debt      += mintAmount;
            totalDebt   += mintAmount;
            psundai.mint(msg.sender, mintAmount);
            emit Mint(msg.sender, mintAmount, _collateralRatio(msg.sender));
        } else if (mintAmount > 0) {
            emit DebtCeilingReached(totalDebt, ceiling);
        }
    }

    // ── Mint ──────────────────────────────────────────────────────────────────
    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero mint");
        require(isUXSafe(), "System not safe for minting");
        require(totalDebt + amount <= _effectiveDebtCeiling(), "Debt ceiling reached");

        _touch(msg.sender);
        _registerVault(msg.sender);

        require(systemHealth() >= MIN_SYSTEM_HEALTH, "System undercollateralized");
        require(vaults[msg.sender].debt + amount <= _vaultCap(), "Vault cap reached");

        uint256 price = _safeMintPrice();
        require(_checkSafe(vaults[msg.sender].collateral, vaults[msg.sender].debt + amount, price), "Not enough collateral");

        Vault storage v = vaults[msg.sender];
        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        v.debt    += amount;
        totalDebt += amount;
        psundai.mint(msg.sender, amount);
        emit Mint(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Repay ─────────────────────────────────────────────────────────────────
    function repay(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(amount > 0 && v.debt >= amount, "Invalid repay");

        psundai.burn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        emit Repay(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────
    function withdrawPLS(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        _touch(msg.sender);

        uint256 price = v.debt > 0 ? _safeMintPrice() : 0;
        v.collateral    -= amount;
        totalCollateral -= amount;

        if (v.debt > 0) require(_checkSafe(v.collateral, v.debt, price), "Unsafe");

        v.lastWithdrawTime = block.timestamp;
        IWPLS(address(wpls)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function withdrawWPLS(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        _touch(msg.sender);

        uint256 price = v.debt > 0 ? _safeMintPrice() : 0;
        v.collateral    -= amount;
        totalCollateral -= amount;

        if (v.debt > 0) require(_checkSafe(v.collateral, v.debt, price), "Unsafe");

        v.lastWithdrawTime = block.timestamp;
        wpls.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Repay + auto-withdraw ─────────────────────────────────────────────────
    function repayAndAutoWithdraw(uint256 repayAmount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(repayAmount > 0 && v.debt >= repayAmount, "Invalid repay");

        psundai.burn(msg.sender, repayAmount);
        v.debt    -= repayAmount;
        totalDebt -= repayAmount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        uint256 price = _safeMintPrice();

        if (v.debt == 0) {
            uint256 amt     = v.collateral;
            totalCollateral -= amt;
            delete vaults[msg.sender];
            IWPLS(address(wpls)).withdraw(amt);
            _sendETH(msg.sender, amt);
            emit Withdraw(msg.sender, amt, 0);
            emit Repay(msg.sender, repayAmount, 0);
            return;
        }

        uint256 required = (v.debt * COLLATERAL_RATIO * 1e18) / (price * 100);
        if (v.collateral > required) {
            uint256 withdrawable = v.collateral - required;
            v.collateral        = required;
            totalCollateral    -= withdrawable;
            IWPLS(address(wpls)).withdraw(withdrawable);
            _sendETH(msg.sender, withdrawable);
            emit Withdraw(msg.sender, withdrawable, _collateralRatio(msg.sender));
        }

        emit Repay(msg.sender, repayAmount, _collateralRatio(msg.sender));
    }

    function autoRepayToHealth() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        if (v.debt == 0) return;
        uint256 price        = _safeMintPrice();
        uint256 requiredDebt = (v.collateral * price * 100) / (COLLATERAL_RATIO * 1e18);
        if (v.debt > requiredDebt) {
            uint256 repayAmt = v.debt - requiredDebt;
            psundai.burn(msg.sender, repayAmt);
            v.debt    -= repayAmt;
            totalDebt -= repayAmt;
            emit Repay(msg.sender, repayAmt, _collateralRatio(msg.sender));
        }
    }

    // ── v9: Stability Pool ────────────────────────────────────────────────────

    /// @notice Deposit pSunDAI into the Stability Pool. Harvests any pending
    ///         collateral gain first. Requires prior ERC20 approval.
    function provideToStabilityPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _harvestAndUpdateSnapshot(msg.sender);

        IERC20(address(psundai)).safeTransferFrom(msg.sender, address(this), amount);

        stabilityDeposits[msg.sender] += amount;
        totalStabilityDeposits        += amount;

        emit StabilityDeposit(msg.sender, amount);
    }

    /// @notice Withdraw up to `amount` of your compounded Stability Pool deposit.
    ///         Harvests any pending collateral gain first.
    function withdrawFromStabilityPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _harvestAndUpdateSnapshot(msg.sender);

        uint256 currentDeposit = stabilityDeposits[msg.sender];
        require(currentDeposit > 0, "No deposit");
        uint256 withdrawAmount = amount > currentDeposit ? currentDeposit : amount;

        stabilityDeposits[msg.sender] = currentDeposit - withdrawAmount;
        totalStabilityDeposits        -= withdrawAmount;

        IERC20(address(psundai)).safeTransfer(msg.sender, withdrawAmount);
        emit StabilityWithdraw(msg.sender, withdrawAmount);
    }

    /// @notice Claim any pending collateral gain without depositing/withdrawing.
    function claimCollateralGain() external nonReentrant {
        require(stabilityDeposits[msg.sender] > 0, "No deposit");
        _harvestAndUpdateSnapshot(msg.sender);
    }

    /// @notice Pays out the depositor's pending collateral gain and re-snapshots
    ///         their compounded deposit against current P/S/scale/epoch.
    function _harvestAndUpdateSnapshot(address depositor) internal {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit > 0) {
            uint256 collGain   = _getDepositorCollateralGain(depositor);
            uint256 compounded = _getCompoundedStabilityDeposit(depositor);

            stabilityDeposits[depositor] = compounded;

            if (collGain > 0) {
                stabilityPoolCollateral -= collGain;
                IWPLS(address(wpls)).withdraw(collGain);
                _sendETH(depositor, collGain);
                emit CollateralGainWithdrawn(depositor, collGain);
            }
        }

        depositSnapshots[depositor] = StabilitySnapshot({
            P:     P,
            S:     epochToScaleToSum[currentEpoch][currentScale],
            scale: currentScale,
            epoch: currentEpoch
        });
    }

    function _getCompoundedStabilityDeposit(address depositor) internal view returns (uint256) {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit == 0) return 0;
        StabilitySnapshot memory snap = depositSnapshots[depositor];
        if (snap.epoch < currentEpoch) return 0; // pool fully wiped since this snapshot

        uint128 scaleDiff = currentScale - snap.scale;
        uint256 compounded;
        if (scaleDiff == 0) {
            compounded = (initialDeposit * P) / snap.P;
        } else if (scaleDiff == 1) {
            compounded = (initialDeposit * P) / snap.P / SCALE_FACTOR;
        } else {
            compounded = 0;
        }
        if (compounded < 1e9) return 0; // negligible dust after heavy decay
        return compounded;
    }

    function _getDepositorCollateralGain(address depositor) internal view returns (uint256) {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit == 0) return 0;
        StabilitySnapshot memory snap = depositSnapshots[depositor];

        uint128 gainEpoch = snap.epoch < currentEpoch ? snap.epoch : currentEpoch;

        uint256 firstPortion  = epochToScaleToSum[gainEpoch][snap.scale] - snap.S;
        uint256 secondPortion = epochToScaleToSum[gainEpoch][snap.scale + 1] / SCALE_FACTOR;

        return (initialDeposit * (firstPortion + secondPortion)) / snap.P / DECIMAL_PRECISION;
    }

    function getCompoundedStabilityDeposit(address depositor) external view returns (uint256) {
        return _getCompoundedStabilityDeposit(depositor);
    }

    function getDepositorCollateralGain(address depositor) external view returns (uint256) {
        return _getDepositorCollateralGain(depositor);
    }

    function getStabilityPoolStats() external view returns (
        uint256 totalDeposits,
        uint256 totalCollateralHeld,
        uint256 currentP,
        uint128 scale,
        uint128 epoch
    ) {
        return (totalStabilityDeposits, stabilityPoolCollateral, P, currentScale, currentEpoch);
    }

    /// @notice Applies a liquidation to the Stability Pool: burns `debtToOffset`
    ///         pSunDAI from the pool's own held balance and credits `collToAdd`
    ///         WPLS to depositors pro-rata via the Product-Sum accounting.
    ///         Standard Liquity-style algorithm — see contract header.
    function _offset(uint256 debtToOffset, uint256 collToAdd) internal {
        if (totalStabilityDeposits == 0 || debtToOffset == 0) return;

        uint256 collNumerator        = collToAdd * DECIMAL_PRECISION + lastCollateralError_Offset;
        uint256 collGainPerUnitStaked = collNumerator / totalStabilityDeposits;
        lastCollateralError_Offset    = collNumerator - (collGainPerUnitStaked * totalStabilityDeposits);

        uint256 debtNumerator     = debtToOffset * DECIMAL_PRECISION + lastDebtLossError_Offset;
        uint256 lossPerUnitStaked = debtNumerator / totalStabilityDeposits;
        if (lossPerUnitStaked > DECIMAL_PRECISION) lossPerUnitStaked = DECIMAL_PRECISION;
        lastDebtLossError_Offset  = debtNumerator - (lossPerUnitStaked * totalStabilityDeposits);

        uint256 newProductFactor = DECIMAL_PRECISION - lossPerUnitStaked;

        uint128 epochCached = currentEpoch;
        uint128 scaleCached = currentScale;
        uint256 pCached      = P;

        // No division by DECIMAL_PRECISION here: collGainPerUnitStaked and P are
        // both already DECIMAL_PRECISION-scaled, and _getDepositorCollateralGain
        // divides by both P_snapshot and DECIMAL_PRECISION when reading this sum
        // back out - matching the standard Liquity StabilityPool algorithm.
        uint256 marginalCollGain = collGainPerUnitStaked * pCached;
        epochToScaleToSum[epochCached][scaleCached] += marginalCollGain;

        uint256 newP;
        if (newProductFactor == 0) {
            currentEpoch = epochCached + 1;
            currentScale = 0;
            newP = DECIMAL_PRECISION;
            emit StabilityPoolEmptied(currentEpoch);
        } else if ((pCached * newProductFactor) / DECIMAL_PRECISION < SCALE_FACTOR) {
            // Single division here (not /DECIMAL_PRECISION twice): this
            // rescales P *up* by SCALE_FACTOR so it doesn't underflow to
            // dust/zero on repeated heavy losses. The read side (compounded
            // deposit, collateral gain) divides back down by SCALE_FACTOR
            // once per scale step crossed - see _getCompoundedStabilityDeposit
            // and the secondPortion term in _getDepositorCollateralGain.
            newP = (pCached * newProductFactor * SCALE_FACTOR) / DECIMAL_PRECISION;
            currentScale = scaleCached + 1;
        } else {
            newP = (pCached * newProductFactor) / DECIMAL_PRECISION;
        }
        require(newP > 0, "P underflow");
        P = newP;

        totalStabilityDeposits  -= debtToOffset;
        stabilityPoolCollateral += collToAdd;

        psundai.burn(address(this), debtToOffset);

        emit StabilityPoolOffset(debtToOffset, collToAdd);
    }

    /// @notice Distributes protocol fee revenue (stability fee, flash-mint
    ///         fee) to Stability Pool depositors as auto-compounding yield,
    ///         falling back to surplusBuffer when the pool is empty (nobody
    ///         to pay). Unlike _offset (a LOSS, shrinking P), this is a GAIN:
    ///         it mints `feeAmount` new pSunDAI directly into the pool's
    ///         custody and grows P by the same multiplicative mechanism, just
    ///         upward instead of downward. Every depositor's existing
    ///         compoundedDeposit = initialDeposit * P / snapshotP formula
    ///         picks this up automatically and proportionally — no separate
    ///         claim, no new accumulator needed, and (unlike the loss side) no
    ///         scale/epoch rescaling is needed either, since growth can never
    ///         underflow P to zero the way repeated losses can.
    function _distributeFee(uint256 feeAmount) internal {
        if (feeAmount == 0) return;

        if (totalStabilityDeposits == 0) {
            surplusBuffer += feeAmount;
            return;
        }

        uint256 gainNumerator = feeAmount * DECIMAL_PRECISION + lastFeeGainError_Offset;
        uint256 feeGainPerUnitStaked = gainNumerator / totalStabilityDeposits;
        lastFeeGainError_Offset = gainNumerator - (feeGainPerUnitStaked * totalStabilityDeposits);

        uint256 newProductFactor = DECIMAL_PRECISION + feeGainPerUnitStaked;
        P = (P * newProductFactor) / DECIMAL_PRECISION;

        totalStabilityDeposits += feeAmount;
        psundai.mint(address(this), feeAmount);

        emit StabilityPoolFeeDistributed(feeAmount);
    }

    // ── Dutch auction clock ───────────────────────────────────────────────────

    /// @notice Mark a vault as undercollateralized to start the bonus graduation clock.
    function markUndercollateralized(address user) external {
        Vault storage v = vaults[user];
        require(v.debt > 0, "No debt");
        if (v.undercollateralizedSince != 0) return;

        (uint256 price,) = _liquidationPriceView();
        uint256 ratio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(ratio < LIQUIDATION_RATIO, "Vault is safe");

        v.undercollateralizedSince = block.timestamp;
        emit VaultMarkedUndercollateralized(user, block.timestamp);
    }

    // ── Liquidation ───────────────────────────────────────────────────────────

    /// @notice Shared liquidation math for liquidate(), liquidateWithFlashMint(),
    ///         and liquidateFromStabilityPool(): validates the vault is actually
    ///         liquidatable, starts the Dutch-auction clock if needed, and
    ///         returns the collateral reward for repaying `repayAmount` at
    ///         `price`. Does not move any tokens or collateral itself.
    function _liquidationReward(Vault storage v, uint256 repayAmount, uint256 price) internal returns (uint256 reward) {
        uint256 currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(currentRatio < LIQUIDATION_RATIO, "Vault is safe");

        if (v.undercollateralizedSince == 0) {
            v.undercollateralizedSince = block.timestamp;
        }

        uint256 base = Math.mulDiv(repayAmount, 1e18, price);
        uint256 elapsed = block.timestamp - v.undercollateralizedSince;
        if (elapsed > AUCTION_TIME) elapsed = AUCTION_TIME;
        uint256 bonusBps = MIN_BONUS_BPS + ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME);
        reward = base + (base * bonusBps) / 10000;
        if (reward > v.collateral) reward = v.collateral;
    }

    /// @notice Post-liquidation bookkeeping shared by all liquidation paths.
    function _finalizeLiquidation(Vault storage v, uint256 price) internal {
        if (v.debt == 0) {
            v.undercollateralizedSince = 0;
        } else {
            uint256 newRatio = (v.collateral * price * 100) / (v.debt * 1e18);
            if (newRatio >= LIQUIDATION_RATIO) v.undercollateralizedSince = 0;
        }
    }

    /// @notice Liquidate an undercollateralized vault. Caller must already hold
    ///         the pSunDAI being repaid. For vaults the Stability Pool can cover,
    ///         liquidateFromStabilityPool() is more capital-efficient for callers
    ///         (no pre-held pSunDAI required beyond gas).
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _touch(user);

        require(v.debt > 0, "No debt");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");
        require(repayAmount * 10000 >= v.debt * MIN_LIQUIDATION_BPS, "Too small");

        (uint256 price, bool isSpot) = _liquidationPrice();
        uint256 reward = _liquidationReward(v, repayAmount, price);

        psundai.burn(msg.sender, repayAmount);
        v.debt           -= repayAmount;
        totalDebt        -= repayAmount;
        v.collateral     -= reward;
        totalCollateral  -= reward;

        _finalizeLiquidation(v, price);

        IWPLS(address(wpls)).withdraw(reward);
        _sendETH(msg.sender, reward);
        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user), isSpot);
    }

    /// @notice v9: permissionless liquidation absorbed atomically by the
    ///         Stability Pool — no pre-held pSunDAI or DEX resale needed by the
    ///         caller. Offsets min(v.debt, totalStabilityDeposits) against the
    ///         pool at the same Dutch-auction reward curve as liquidate(). The
    ///         caller receives a small flat tip (gas compensation); the rest of
    ///         the reward goes to Stability Pool depositors, since it's their
    ///         capital doing the absorbing. If the pool can't cover the full
    ///         debt, the remainder stays on the vault for liquidate() or
    ///         clearBadDebt() to finish.
    function liquidateFromStabilityPool(address user) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _touch(user);

        require(v.debt > 0, "No debt");
        require(totalStabilityDeposits > 0, "SP empty - use liquidate()");

        (uint256 price, bool isSpot) = _liquidationPrice();
        uint256 debtToOffset = v.debt < totalStabilityDeposits ? v.debt : totalStabilityDeposits;

        uint256 totalReward = _liquidationReward(v, debtToOffset, price);

        uint256 base = Math.mulDiv(debtToOffset, 1e18, price);
        uint256 callerTip = (base * LIQUIDATION_CALLER_TIP_BPS) / 10000;
        if (callerTip > totalReward) callerTip = totalReward;
        uint256 poolReward = totalReward - callerTip;

        v.debt          -= debtToOffset;
        totalDebt        -= debtToOffset;
        v.collateral     -= totalReward;
        totalCollateral  -= totalReward;

        _finalizeLiquidation(v, price);
        _offset(debtToOffset, poolReward);

        if (callerTip > 0) {
            IWPLS(address(wpls)).withdraw(callerTip);
            _sendETH(msg.sender, callerTip);
        }

        emit LiquidatedFromStabilityPool(user, debtToOffset, poolReward, callerTip, msg.sender);
        emit Liquidation(user, debtToOffset, msg.sender, totalReward, _collateralRatio(user), isSpot);
    }

    /// @notice Liquidate without pre-holding pSunDAI. Caller must be a contract
    ///         implementing IFlashLiquidationReceiver. The vault sends the WPLS
    ///         reward collateral first, then calls back into msg.sender's own
    ///         onFlashLiquidation() — not an arbitrary target. Requires
    ///         repayment (+ a small fee routed into surplusBuffer) by the end of
    ///         the same transaction or the whole call reverts.
    function liquidateWithFlashMint(
        address user,
        uint256 repayAmount,
        bytes calldata data
    ) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _touch(user);

        require(v.debt > 0, "No debt");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");
        require(repayAmount * 10000 >= v.debt * MIN_LIQUIDATION_BPS, "Too small");

        (uint256 price, bool isSpot) = _liquidationPrice();
        uint256 reward = _liquidationReward(v, repayAmount, price);

        v.collateral    -= reward;
        totalCollateral -= reward;
        wpls.safeTransfer(msg.sender, reward);

        uint256 feeAmount = (repayAmount * FLASH_FEE_BPS) / 10_000;
        uint256 amountOwed = repayAmount + feeAmount;

        IFlashLiquidationReceiver(msg.sender).onFlashLiquidation(user, reward, amountOwed, data);

        require(psundai.balanceOf(msg.sender) >= amountOwed, "Insufficient repay");
        psundai.burn(msg.sender, amountOwed);
        _distributeFee(feeAmount);

        v.debt    -= repayAmount;
        totalDebt -= repayAmount;
        _finalizeLiquidation(v, price);

        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user), isSpot);
    }

    // ── Bad debt clearing ─────────────────────────────────────────────────────

    /// @notice Voluntarily unwind a fully-underwater vault (collateral value <
    ///         100% of debt, and neither the Stability Pool nor a keeper has
    ///         covered it). Caller repays `repayAmount` (up to v.debt) and
    ///         receives collateral strictly pro-rata:
    ///         collateralOut = v.collateral * repayAmount / v.debt, with NO
    ///         bonus — the position is insolvent, so a bonus would only deepen
    ///         the loss. Because payout is exactly proportional and the vault is
    ///         underwater by definition, a caller can never receive collateral
    ///         worth more than they paid: this is strictly a voluntary,
    ///         loss-taking cleanup action, never a profit opportunity.
    ///
    ///         v9 fix: previously (v8) this function gave 100% of a vault's
    ///         collateral away for FREE once collateral value dipped under
    ///         100% of debt, checked against the manipulable spot price — an
    ///         attacker could suppress spot to trigger it on an otherwise
    ///         healthy vault and walk away with its collateral. Requiring real,
    ///         proportional repayment removes that exploit at the root; using
    ///         the oracle's clamped getLiquidationPrice() for the underwater
    ///         check closes the manipulation vector on the trigger itself.
    function clearBadDebt(address user, uint256 repayAmount) external nonReentrant {
        Vault storage v = vaults[user];
        _touch(user);
        require(v.debt > 0 && v.collateral > 0, "Nothing to clear");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");

        (uint256 price,) = _liquidationPriceView();
        uint256 collateralValue = (v.collateral * price) / 1e18;
        require(collateralValue < v.debt, "Not underwater - use liquidate()");

        uint256 collateralOut = (v.collateral * repayAmount) / v.debt;

        psundai.burn(msg.sender, repayAmount);

        v.debt          -= repayAmount;
        v.collateral    -= collateralOut;
        totalDebt        -= repayAmount;
        totalCollateral  -= collateralOut;

        if (v.debt == 0) {
            if (v.collateral > 0) {
                totalCollateral -= v.collateral;
                v.collateral = 0;
            }
            delete vaults[user];
        }

        IWPLS(address(wpls)).withdraw(collateralOut);
        _sendETH(msg.sender, collateralOut);

        emit BadDebtCleared(user, collateralOut, repayAmount, msg.sender);
    }

    /// @notice Burn pSunDAI to directly cancel bad debt accumulated via the
    ///         interest-accrual dust-clearing path.
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(badDebtAccumulated >= amount, "Exceeds outstanding bad debt");
        psundai.burn(msg.sender, amount);
        badDebtAccumulated -= amount;
        emit DebtSettled(amount, msg.sender);
    }

    /// @notice Manually trigger surplus-to-bad-debt reconciliation.
    function reconcile() external {
        _reconcile();
    }

    // ── Emergency unlock (30-day, zero debt) ──────────────────────────────────
    function emergencyUnlock() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(v.debt == 0, "Repay first");
        require(v.collateral > 0, "No collateral");
        require(block.timestamp > v.lastDepositTime + 30 days, "Active");

        uint256 amt     = v.collateral;
        v.collateral    = 0;
        totalCollateral -= amt;
        IWPLS(address(wpls)).withdraw(amt);
        _sendETH(msg.sender, amt);
        emit EmergencyWithdraw(msg.sender, amt);
    }

    // ── Oracle-death emergency exits ──────────────────────────────────────────
    function emergencyRepay(uint256 amount) external nonReentrant {
        require(isOracleDead(), "Oracle alive - use repay()");
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(amount > 0 && v.debt >= amount, "Invalid repay");

        psundai.burn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        emit EmergencyRepay(msg.sender, amount);
        emit Repay(msg.sender, amount, 0);
    }

    function emergencyWithdrawPLS(uint256 amount) external nonReentrant {
        require(isOracleDead(), "Oracle alive - use withdrawPLS()");
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(v.debt == 0, "Repay debt first via emergencyRepay()");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");

        v.collateral    -= amount;
        totalCollateral -= amount;
        v.lastWithdrawTime = block.timestamp;

        IWPLS(address(wpls)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit EmergencyWithdrawOracleDead(msg.sender, amount);
    }

    // ── View functions ────────────────────────────────────────────────────────

    function vaultInfo(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 collateralUSD,
        uint256 ratio,
        uint256 mintable,
        bool    oracleHealthy,
        uint256 price,
        uint256 systemRatio,
        bool    spotLiquidationActive
    ) {
        Vault storage v = vaults[user];
        collateral = v.collateral;
        debt       = v.debt;

        (uint256 p, uint256 ts) = oracle.peekPriceView();
        price         = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        oracleHealthy = (p > 0 && block.timestamp - ts <= 600);
        collateralUSD = (collateral * price) / 1e18;
        ratio         = debt == 0 ? type(uint256).max : (collateral * price * 100) / (debt * 1e18);
        uint256 safeLimit = (collateralUSD * 100) / COLLATERAL_RATIO;
        uint256 ceiling   = _effectiveDebtCeiling();
        uint256 vCap      = _vaultCap();
        uint256 userMax   = safeLimit > debt ? safeLimit - debt : 0;
        userMax           = Math.min(userMax, debt < vCap ? vCap - debt : 0);
        mintable          = totalDebt < ceiling ? Math.min(userMax, ceiling - totalDebt) : 0;
        systemRatio          = systemHealth();
        spotLiquidationActive = oracle.isSpotLiquidationEnabled();
    }

    function maxMint(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.collateral == 0) return 0;
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        uint256 price    = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        uint256 valueUSD = (v.collateral * price) / 1e18;
        uint256 limit    = (valueUSD * 100) / COLLATERAL_RATIO;
        uint256 userMax  = limit > v.debt ? limit - v.debt : 0;
        uint256 vCap     = _vaultCap();
        userMax          = Math.min(userMax, v.debt < vCap ? vCap - v.debt : 0);
        uint256 ceiling  = _effectiveDebtCeiling();
        uint256 room     = totalDebt < ceiling ? ceiling - totalDebt : 0;
        return Math.min(userMax, room);
    }

    function repayToHealth(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return 0;
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        uint256 price   = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        uint256 maxDebt = (v.collateral * price * 100) / (COLLATERAL_RATIO * 1e18);
        return v.debt > maxDebt ? v.debt - maxDebt : 0;
    }

    function isLiquidatable(address user) external view returns (bool canLiquidate, uint256 currentRatio, bool atSpotPrice) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (false, type(uint256).max, false);
        (uint256 price, bool isSpot) = _liquidationPriceView();
        currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        canLiquidate = currentRatio < LIQUIDATION_RATIO;
        atSpotPrice  = isSpot;
    }

    function liquidationInfo(address user) external view returns (
        uint256 debt,
        uint256 minRepay,
        uint256 bonusBps,
        uint256 auctionElapsed,
        bool    isUnderwater
    ) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (0, 0, 0, 0, false);
        debt     = v.debt;
        minRepay = (v.debt * MIN_LIQUIDATION_BPS) / 10000;
        auctionElapsed = v.undercollateralizedSince == 0
            ? 0
            : block.timestamp - v.undercollateralizedSince;
        uint256 elapsed = auctionElapsed > AUCTION_TIME ? AUCTION_TIME : auctionElapsed;
        bonusBps = MIN_BONUS_BPS + ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME);

        (uint256 price,) = _liquidationPriceView();
        uint256 collateralValue = (v.collateral * price) / 1e18;
        isUnderwater = collateralValue < v.debt;
    }

    // ── Vault enumeration ──────────────────────────────────────────────────────
    function getVaultCount() external view returns (uint256) {
        return vaultOwners.length;
    }

    function getVaultOwners(uint256 start, uint256 count) external view returns (address[] memory) {
        require(start < vaultOwners.length, "Out of bounds");
        uint256 end = start + count;
        if (end > vaultOwners.length) end = vaultOwners.length;
        address[] memory result = new address[](end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = vaultOwners[start + i];
        }
        return result;
    }

    receive() external payable {}
    fallback() external payable {}
}
