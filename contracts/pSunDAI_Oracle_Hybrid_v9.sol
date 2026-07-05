// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║          pSunDAIoraclePLSXHybrid — ELITE TEAM6 (v9)                  ║
 * ║                                                                      ║
 * ║   Self-Healing Dual-Track Oracle for Autonomous Stable Assets        ║
 * ║                                                                      ║
 * ║   Carries forward all v8 logic unchanged (dual-track pricing,        ║
 * ║   liquidity-weighted median, asymmetric confirmation state machine,  ║
 * ║   staircase-drift protection, rolling liquidity-depth floor). v9     ║
 * ║   hardens the parameters and adds one new read path after an         ║
 * ║   external review found the spot-liquidation arm had no ceiling on   ║
 * ║   manipulation profit and the debt-capacity multiplier was too       ║
 * ║   aggressive for real PulseChain pool depth:                        ║
 * ║                                                                      ║
 * ║   1. getLiquidationPrice() — spot median hard-clamped to within      ║
 * ║      MAX_SPOT_DEVIATION_BPS of the committed TWAP. Previously, once  ║
 * ║      the spot-liquidation arm activated, raw spot was used directly  ║
 * ║      with no bound — a sustained thin-liquidity suppression could    ║
 * ║      inflate liquidation payouts without limit. Now the payout price ║
 * ║      can never diverge from TWAP by more than the clamp, regardless  ║
 * ║      of how far or how long spot is pushed.                         ║
 * ║                                                                      ║
 * ║   2. MIN_VALID_POOLS — both the TWAP median and the spot median now  ║
 * ║      require at least 3 of the 5 pools to be valid before returning  ║
 * ║      a nonzero price, instead of letting 1-2 remaining pools set the ║
 * ║      price alone once others are drained or excluded.                ║
 * ║                                                                      ║
 * ║   3. MIN_RESERVE_USD raised 1,000 -> 10,000 and SPOT_CONFIRM_TIME    ║
 * ║      lengthened 30min -> 90min, raising the cost and duration of     ║
 * ║      sustaining a manipulated price. 10,000 (not a rounder, more     ║
 * ║      aggressive number) was chosen against real observed PulseX pool ║
 * ║      depth at deploy-review time (5 pools ranged $17.6k-$376k) so    ║
 * ║      every pool keeps comfortable headroom above the floor — an      ║
 * ║      immutable threshold sitting close to real, fluctuating pool     ║
 * ║      depth risks pools flapping in and out of validity over time.    ║
 * ║                                                                      ║
 * ║   4. SAFE_CAPACITY_MULTIPLIER cut 20x -> 5x — system debt capacity   ║
 * ║      is now a much tighter multiple of real DEX depth.               ║
 * ║                                                                      ║
 * ║   Dev: ELITE TEAM6 | https://www.sundaitoken.com                     ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

contract pSunDAIoraclePLSXHybrid_v9 {
    using Math for uint256;

    string public constant VERSION = "pSunDAIoraclePLSXHybrid_v9";

    // ── Pair data ────────────────────────────────────────────────────────────
    struct PairData {
        IUniswapV2Pair pair;
        uint256 priceCumulativeLast;
        uint40  oracleTimestampLast; // oracle's own last-sample time
        uint8   stableDecimals;      // cached at init
        bool    wplsIsToken0;
    }

    struct PendingPriceUpdate {
        uint256 targetPrice;
        uint256 firstSeenTime;
        bool    isActive;
    }

    struct RollingSample {
        uint256 price;
        uint40  ts;
    }

    struct LiquiditySample {
        uint256 depth;
        uint40  ts;
    }

    PairData public pairDAIv1;
    PairData public pairDAIv2;
    PairData public pairUSDCv1;
    PairData public pairUSDCv2;
    PairData public pairUSDT;

    // ── Immutable addresses ──────────────────────────────────────────────────
    address public immutable wpls;
    address public immutable dai;
    address public immutable usdc;
    address public immutable usdt;
    address public immutable deployer;

    address public vault;
    bool    public immutableSet;

    // ── TWAP track state ─────────────────────────────────────────────────────
    uint256 public lastPrice;
    uint256 public lastUpdateTimestamp;
    uint256 public lastPokeTime;
    PendingPriceUpdate public pendingUpdate;

    // ── Spot warning track state ─────────────────────────────────────────────
    // Set when 5-pool spot median first drops SPOT_WARNING_BPS below lastPrice.
    // Cleared when spot recovers. isSpotLiquidationEnabled() returns true when
    // this has been nonzero for >= SPOT_CONFIRM_TIME.
    uint256 public spotWarningStart;

    // ── Rolling drift-tracking state ─────────────────────────────────────────
    // Fixed-size ring buffer of recent confirmed lastPrice values, used to detect
    // "staircase" manipulation: many small sub-threshold instant updates chained
    // together to walk the price further than a single large move would be
    // allowed to do without triggering the confirmation delay.
    uint8 public constant ROLLING_BUF_SIZE = 8;
    RollingSample[ROLLING_BUF_SIZE] public rollingBuf;
    uint8 public rollingHead;
    uint8 public rollingCount;
    uint256 public constant STAIRCASE_WINDOW = 30 minutes;
    uint256 public constant ROLLING_SAMPLE_INTERVAL = STAIRCASE_WINDOW / ROLLING_BUF_SIZE;

    // ── Liquidity-depth tracking state ───────────────────────────────────────
    // Same ring-buffer pattern applied to _sumValidReserves(), so maxSafeDebt()
    // is based on a rolling MINIMUM of recent depth rather than the instantaneous
    // current value. Closes a flash-liquidity attack.
    uint8 public constant LIQUIDITY_BUF_SIZE = 8;
    LiquiditySample[LIQUIDITY_BUF_SIZE] public liquidityBuf;
    uint8 public liquidityHead;
    uint8 public liquidityCount;
    uint256 public constant LIQUIDITY_WINDOW = 24 hours;
    uint256 public constant LIQUIDITY_SAMPLE_INTERVAL = LIQUIDITY_WINDOW / LIQUIDITY_BUF_SIZE;

    // ── TWAP constants ───────────────────────────────────────────────────────
    uint256 public constant PRECISION              = 1e18;
    uint256 public constant MIN_RESERVE_USD        = 10_000 * 1e18; // v9: was 1_000
    uint256 public constant MAX_PRICE_AGE          = 300;
    uint256 public constant MIN_TWAP_INTERVAL      = 60;
    uint256 public constant CONFIRM_TIME_DOWN      = 4 hours;
    uint256 public constant CONFIRM_TIME_UP        = 30 minutes;
    uint256 public constant STEP_SIZE_DOWN_BPS     = 300;
    uint256 public constant STEP_SIZE_UP_BPS       = 1000;
    uint256 public constant INSTANT_UPDATE_DOWN_BPS = 100;
    uint256 public constant INSTANT_UPDATE_UP_BPS   = 500;
    uint256 public constant RECOVERY_BPS           = 300;
    uint256 public constant TARGET_SHIFT_BPS       = 300;
    uint256 public constant MIN_POKE_INTERVAL      = 30 minutes;

    // ── v9: minimum number of valid pools required to trust the median ───────
    // Below this, a minority of remaining/manipulated pools could otherwise
    // dominate the reported price. Both the TWAP median and the spot median
    // return invalid (0) when fewer than this many pools pass their checks.
    uint8 public constant MIN_VALID_POOLS = 3;

    // ── Spot warning constants ────────────────────────────────────────────────
    // Spot must be this far below TWAP before the warning clock starts.
    uint256 public constant SPOT_WARNING_BPS   = 500;
    // Spot must stay below the threshold for this long before liquidations enable.
    // v9: 30min -> 90min, raising the cost/duration of a sustained manipulation.
    uint256 public constant SPOT_CONFIRM_TIME  = 90 minutes;

    // ── v9: liquidation price clamp ───────────────────────────────────────────
    // getLiquidationPrice() clamps the spot median to within this band of the
    // committed TWAP (lastPrice). Previously, once the spot-liquidation arm
    // activated, raw spot was used directly with no bound on divergence from
    // TWAP, so a sustained suppression could inflate liquidation payouts
    // without limit. The clamp bounds the maximum extractable manipulation
    // profit to a small, fixed amount regardless of how far spot is pushed.
    uint256 public constant MAX_SPOT_DEVIATION_BPS = 1500; // 15%

    // ── Dynamic capacity constants ────────────────────────────────────────────
    // maxSafeDebt() = combined valid-pool reserves * this multiplier.
    // v9: cut 20x -> 5x. 20x authorized system debt up to 20x actual DEX
    // stable-liquidity, which guarantees slippage-driven bad debt if
    // liquidators ever need to dump collateral at scale on thin PulseChain
    // pools. 5x is a materially tighter multiple of real DEX depth.
    uint256 public constant SAFE_CAPACITY_MULTIPLIER = 5;

    // ── Events ───────────────────────────────────────────────────────────────
    event PriceUpdated(uint256 price, uint256 timestamp, bool stepped);
    event ConfirmationStarted(uint256 targetPrice, uint256 confirmTime, bool isDown);
    event ConfirmationCancelled(uint256 reason);
    event SpotWarningTriggered(uint256 spotPrice, uint256 twapPrice, uint256 timestamp);
    event SpotWarningCleared(uint256 spotPrice, uint256 twapPrice);
    event VaultSet(address vault);

    modifier onlyVault() {
        require(msg.sender == vault && vault != address(0), "Not vault");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _pairDAIv1,
        address _pairDAIv2,
        address _pairUSDCv1,
        address _pairUSDCv2,
        address _pairUSDT,
        address _wpls,
        address _dai,
        address _usdc,
        address _usdt
    ) {
        require(
            _pairDAIv1  != address(0) && _pairDAIv2  != address(0) &&
            _pairUSDCv1 != address(0) && _pairUSDCv2 != address(0) &&
            _pairUSDT   != address(0), "Invalid pair"
        );
        require(
            _wpls != address(0) && _dai  != address(0) &&
            _usdc != address(0) && _usdt != address(0), "Invalid token"
        );

        deployer = msg.sender;
        wpls = _wpls; dai = _dai; usdc = _usdc; usdt = _usdt;

        pairDAIv1  = _initPair(_pairDAIv1,  _wpls);
        pairDAIv2  = _initPair(_pairDAIv2,  _wpls);
        pairUSDCv1 = _initPair(_pairUSDCv1, _wpls);
        pairUSDCv2 = _initPair(_pairUSDCv2, _wpls);
        pairUSDT   = _initPair(_pairUSDT,   _wpls);

        (uint256 initialPrice,) = _spotMedian();
        lastPrice           = initialPrice > 0 ? initialPrice : 1e18;
        lastUpdateTimestamp = block.timestamp;
        lastPokeTime        = block.timestamp;
        _pushRollingSample(lastPrice);
        _pushLiquiditySample(_sumValidReserves());

        emit PriceUpdated(lastPrice, block.timestamp, false);
    }

    // ── Pair initialization ──────────────────────────────────────────────────
    function _initPair(address pairAddr, address _wpls) internal view returns (PairData memory d) {
        IUniswapV2Pair p = IUniswapV2Pair(pairAddr);
        bool wplsIs0 = p.token0() == _wpls;
        require(wplsIs0 || p.token1() == _wpls, "Pair missing WPLS");
        address stableToken = wplsIs0 ? p.token1() : p.token0();
        d = PairData({
            pair:                p,
            priceCumulativeLast: wplsIs0 ? p.price0CumulativeLast() : p.price1CumulativeLast(),
            oracleTimestampLast: uint40(block.timestamp),
            stableDecimals:      _getDecimals(stableToken),
            wplsIsToken0:        wplsIs0
        });
    }

    // ── Vault link (one-time) ────────────────────────────────────────────────
    function setVault(address _vault) external {
        require(!immutableSet,          "Vault locked");
        require(msg.sender == deployer, "Only deployer");
        require(_vault != address(0),   "Invalid vault");
        vault        = _vault;
        immutableSet = true;
        emit VaultSet(_vault);
    }

    // ── External oracle interface ────────────────────────────────────────────

    /// @notice Advance TWAP state, update spot warning, return conservative price.
    ///         Called by vault on every user interaction.
    function getPriceWithTimestamp()
        external
        onlyVault
        returns (uint256 price, uint256 timestamp)
    {
        (price, timestamp) = _updateIfNeeded();
        _updateSpotWarning(lastPrice); // always refresh spot warning, even if TWAP didn't move
        _pushLiquiditySample(_sumValidReserves()); // rate-gated internally; feeds maxSafeDebt()'s rolling minimum
        require(price > 0, "Invalid price");
    }

    /// @notice Read conservative TWAP price without advancing state.
    function peekPriceView() external view returns (uint256 price, uint256 timestamp) {
        if (block.timestamp - lastUpdateTimestamp > 24 hours) {
            (price,) = _spotMedian();
            if (price == 0) return (lastPrice, lastUpdateTimestamp);
            return (price, block.timestamp);
        }
        return (lastPrice, lastUpdateTimestamp);
    }

    /// @notice Current 5-pool liquidity-weighted spot median. Used by vault when
    ///         spot liquidation is enabled. Unclamped — see getLiquidationPrice()
    ///         for the manipulation-bounded price actually used for liquidation.
    function getSpotPrice() external view returns (uint256 price) {
        (price,) = _spotMedian();
    }

    /// @notice v9: price to use for liquidation eligibility and reward calculation.
    ///         When the spot-liquidation arm is active (sustained divergence,
    ///         SPOT_CONFIRM_TIME elapsed), returns the spot median hard-clamped
    ///         to within MAX_SPOT_DEVIATION_BPS of the committed TWAP — bounding
    ///         the maximum manipulation profit regardless of how far or how long
    ///         spot is suppressed. Otherwise returns the TWAP with isSpot=false.
    function getLiquidationPrice() external view returns (uint256 price, bool isSpot) {
        if (spotWarningStart != 0 && block.timestamp - spotWarningStart >= SPOT_CONFIRM_TIME) {
            (uint256 spot,) = _spotMedian();
            if (spot > 0 && lastPrice > 0) {
                uint256 lower = (lastPrice * (10_000 - MAX_SPOT_DEVIATION_BPS)) / 10_000;
                uint256 upper = (lastPrice * (10_000 + MAX_SPOT_DEVIATION_BPS)) / 10_000;
                uint256 clamped = spot;
                if (clamped < lower) clamped = lower;
                if (clamped > upper) clamped = upper;
                return (clamped, true);
            }
        }
        return (lastPrice, false);
    }

    /// @notice True when spot has been SPOT_WARNING_BPS below TWAP for SPOT_CONFIRM_TIME.
    ///         When true, the vault switches to spot price for liquidation eligibility.
    function isSpotLiquidationEnabled() external view returns (bool) {
        if (spotWarningStart == 0) return false;
        return block.timestamp - spotWarningStart >= SPOT_CONFIRM_TIME;
    }

    /// @notice How long the spot warning has been active (0 if not active).
    function spotWarningElapsed() external view returns (uint256) {
        if (spotWarningStart == 0) return 0;
        return block.timestamp - spotWarningStart;
    }

    function isStale(uint256 threshold) external view returns (bool) {
        return block.timestamp - lastUpdateTimestamp > threshold;
    }

    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastUpdateTimestamp) < (MAX_PRICE_AGE * 2);
    }

    /// @notice Manipulation-resistant debt capacity derived from real pool depth.
    ///         min(current, rolling-24h-minimum) of every currently-valid pool's
    ///         stable-side reserve, times SAFE_CAPACITY_MULTIPLIER (v9: 5x).
    function maxSafeDebt() external view returns (uint256) {
        uint256 current = _sumValidReserves();
        (uint256 windowMin, bool found) = _minLiquidityInWindow();
        uint256 effectiveDepth = current;
        if (found && windowMin < effectiveDepth) {
            effectiveDepth = windowMin;
        }
        return effectiveDepth * SAFE_CAPACITY_MULTIPLIER;
    }

    // ── Public poke (rate-limited, 30min) ────────────────────────────────────
    function poke() external {
        require(block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL, "Poke cooldown");
        lastPokeTime = block.timestamp;
        _updateIfValid();
        _updateSpotWarning(lastPrice);
        _pushLiquiditySample(_sumValidReserves());
    }

    function canPoke() external view returns (bool) {
        return block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL;
    }

    function timeUntilNextPoke() external view returns (uint256) {
        if (block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL) return 0;
        return (lastPokeTime + MIN_POKE_INTERVAL) - block.timestamp;
    }

    // ── Spot warning track ───────────────────────────────────────────────────

    /// @notice Compares fresh 5-pool spot median against conservative TWAP.
    ///         If spot has been SPOT_WARNING_BPS below TWAP continuously for
    ///         SPOT_CONFIRM_TIME, the spot liquidation arm activates.
    ///         This runs on every vault interaction and every poke() — no keeper needed.
    function _updateSpotWarning(uint256 twapPrice) internal {
        if (twapPrice == 0) return;
        (uint256 spot,) = _spotMedian();
        if (spot == 0) return; // not enough valid pools — can't determine

        uint256 warningThreshold = (twapPrice * (10000 - SPOT_WARNING_BPS)) / 10000;

        if (spot < warningThreshold) {
            if (spotWarningStart == 0) {
                spotWarningStart = block.timestamp;
                emit SpotWarningTriggered(spot, twapPrice, block.timestamp);
            }
            // else: clock already running
        } else {
            if (spotWarningStart != 0) {
                spotWarningStart = 0;
                emit SpotWarningCleared(spot, twapPrice);
            }
        }
    }

    // ── Internal TWAP update logic ───────────────────────────────────────────

    function _updateIfNeeded() internal returns (uint256, uint256) {
        if (block.timestamp - lastUpdateTimestamp > MIN_TWAP_INTERVAL) {
            return _updateIfValid();
        }
        return (lastPrice, lastUpdateTimestamp);
    }

    function _updateIfValid() internal returns (uint256, uint256) {
        uint256 newPrice = _getMedianPrice();
        if (newPrice == 0) return (lastPrice, lastUpdateTimestamp);

        if (lastPrice == 1e18 || lastPrice == 0) {
            _setLastPrice(newPrice);
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        return _processPriceUpdate(newPrice);
    }

    function _getMedianPrice() internal returns (uint256) {
        uint256[5] memory px;
        bool[5]    memory valid;
        uint8[5]   memory decs;
        uint256[5] memory rawWeight;

        (px[0],, valid[0], rawWeight[0]) = _tryTWAP(pairDAIv1);  decs[0] = pairDAIv1.stableDecimals;
        (px[1],, valid[1], rawWeight[1]) = _tryTWAP(pairDAIv2);  decs[1] = pairDAIv2.stableDecimals;
        (px[2],, valid[2], rawWeight[2]) = _tryTWAP(pairUSDCv1); decs[2] = pairUSDCv1.stableDecimals;
        (px[3],, valid[3], rawWeight[3]) = _tryTWAP(pairUSDCv2); decs[3] = pairUSDCv2.stableDecimals;
        (px[4],, valid[4], rawWeight[4]) = _tryTWAP(pairUSDT);   decs[4] = pairUSDT.stableDecimals;

        uint256[5] memory prices;
        uint256[5] memory weights;
        uint8 count;
        for (uint8 i; i < 5; i++) {
            if (!valid[i] || px[i] == 0) continue;
            prices[count]  = _normalizeTo1e18(px[i], decs[i]);
            weights[count] = rawWeight[i];
            count++;
        }

        // v9: require a minimum number of valid pools before trusting the median.
        if (count < MIN_VALID_POOLS) return 0;
        return _weightedMedian(prices, weights, count);
    }

    // ── Asymmetric price update logic ─────────────────────────────────────────

    function _processPriceUpdate(uint256 newPrice) internal returns (uint256, uint256) {
        uint256 diff = newPrice > lastPrice ? newPrice - lastPrice : lastPrice - newPrice;
        uint256 divergenceBps = (diff * 10_000) / lastPrice;
        bool    isDown        = newPrice < lastPrice;

        uint256 instantThreshold = isDown ? INSTANT_UPDATE_DOWN_BPS : INSTANT_UPDATE_UP_BPS;

        // Staircase fix: even when the single step is small, cumulative drift
        // over the trailing STAIRCASE_WINDOW must also stay within the instant
        // threshold, otherwise many small sub-threshold steps could chain
        // together to walk the price past what a single large move would ever
        // be allowed to do without triggering the confirmation delay.
        uint256 cumulativeDriftBps = _cumulativeDriftBps(newPrice);

        if (divergenceBps <= instantThreshold && cumulativeDriftBps <= instantThreshold) {
            if (pendingUpdate.isActive) {
                delete pendingUpdate;
                emit ConfirmationCancelled(0);
            }
            _setLastPrice(newPrice);
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        return _handleLargeMove(newPrice, divergenceBps);
    }

    function _handleLargeMove(uint256 newPrice, uint256 divergenceBps) internal returns (uint256, uint256) {
        bool isDownward = newPrice < lastPrice;
        if (!pendingUpdate.isActive) return _startConfirmation(newPrice, isDownward);
        return _processPendingUpdate(newPrice, divergenceBps, isDownward);
    }

    function _startConfirmation(uint256 newPrice, bool isDownward) internal returns (uint256, uint256) {
        uint256 confirmTime = isDownward ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
        pendingUpdate = PendingPriceUpdate({
            targetPrice:   newPrice,
            firstSeenTime: block.timestamp,
            isActive:      true
        });
        emit ConfirmationStarted(newPrice, confirmTime, isDownward);
        return (lastPrice, lastUpdateTimestamp);
    }

    function _processPendingUpdate(
        uint256 newPrice,
        uint256 divergenceBps,
        bool    isDownward
    ) internal returns (uint256, uint256) {
        uint256 pendingDiff = newPrice > pendingUpdate.targetPrice
            ? newPrice - pendingUpdate.targetPrice
            : pendingUpdate.targetPrice - newPrice;
        uint256 pendingDivergenceBps = (pendingDiff * 10_000) / pendingUpdate.targetPrice;

        if (pendingDivergenceBps > TARGET_SHIFT_BPS) {
            emit ConfirmationCancelled(1);
            return _startConfirmation(newPrice, isDownward);
        }

        if (divergenceBps <= RECOVERY_BPS) {
            delete pendingUpdate;
            emit ConfirmationCancelled(0);
            _setLastPrice(newPrice);
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        bool    targetIsDown = pendingUpdate.targetPrice < lastPrice;
        uint256 confirmTime  = targetIsDown ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
        if (block.timestamp - pendingUpdate.firstSeenTime < confirmTime) {
            return (lastPrice, lastUpdateTimestamp);
        }

        return _stepTowardTarget();
    }

    function _stepTowardTarget() internal returns (uint256, uint256) {
        bool    targetIsDown = pendingUpdate.targetPrice < lastPrice;
        uint256 stepSizeBps  = targetIsDown ? STEP_SIZE_DOWN_BPS : STEP_SIZE_UP_BPS;
        uint256 maxMove      = (lastPrice * stepSizeBps) / 10_000;

        uint256 remainingDiff = pendingUpdate.targetPrice > lastPrice
            ? pendingUpdate.targetPrice - lastPrice
            : lastPrice - pendingUpdate.targetPrice;

        uint256 updatedPrice;
        if (remainingDiff <= maxMove) {
            updatedPrice = pendingUpdate.targetPrice;
            delete pendingUpdate;
        } else {
            updatedPrice = targetIsDown ? lastPrice - maxMove : lastPrice + maxMove;
        }

        _setLastPrice(updatedPrice);
        emit PriceUpdated(updatedPrice, block.timestamp, true);
        return (updatedPrice, block.timestamp);
    }

    // ── lastPrice mutation + rolling drift buffer ─────────────────────────────

    function _setLastPrice(uint256 newPrice) internal {
        lastPrice           = newPrice;
        lastUpdateTimestamp = block.timestamp;
        _pushRollingSample(newPrice);
    }

    function _pushRollingSample(uint256 price) internal {
        if (rollingCount > 0) {
            uint8 lastIdx = rollingHead == 0 ? ROLLING_BUF_SIZE - 1 : rollingHead - 1;
            if (block.timestamp - rollingBuf[lastIdx].ts < ROLLING_SAMPLE_INTERVAL) return;
        }
        rollingBuf[rollingHead] = RollingSample({price: price, ts: uint40(block.timestamp)});
        rollingHead = uint8((rollingHead + 1) % ROLLING_BUF_SIZE);
        if (rollingCount < ROLLING_BUF_SIZE) rollingCount++;
    }

    function _pushLiquiditySample(uint256 depth) internal {
        if (liquidityCount > 0) {
            uint8 lastIdx = liquidityHead == 0 ? LIQUIDITY_BUF_SIZE - 1 : liquidityHead - 1;
            if (block.timestamp - liquidityBuf[lastIdx].ts < LIQUIDITY_SAMPLE_INTERVAL) return;
        }
        liquidityBuf[liquidityHead] = LiquiditySample({depth: depth, ts: uint40(block.timestamp)});
        liquidityHead = uint8((liquidityHead + 1) % LIQUIDITY_BUF_SIZE);
        if (liquidityCount < LIQUIDITY_BUF_SIZE) liquidityCount++;
    }

    /// @notice Minimum recorded liquidity depth still inside the trailing
    ///         LIQUIDITY_WINDOW. found=false if there isn't enough history yet.
    function _minLiquidityInWindow() internal view returns (uint256 minDepth, bool found) {
        uint256 cutoff = block.timestamp > LIQUIDITY_WINDOW ? block.timestamp - LIQUIDITY_WINDOW : 0;
        minDepth = type(uint256).max;
        for (uint8 i = 0; i < liquidityCount; i++) {
            LiquiditySample memory s = liquidityBuf[i];
            if (uint256(s.ts) >= cutoff) {
                found = true;
                if (s.depth < minDepth) minDepth = s.depth;
            }
        }
    }

    /// @notice Oldest recorded price sample still inside the trailing STAIRCASE_WINDOW.
    ///         Returns found=false if there isn't enough history yet (e.g. shortly
    ///         after deploy) — treated permissively so bootstrap isn't blocked.
    function _oldestSampleInWindow() internal view returns (uint256 price, bool found) {
        uint256 cutoff = block.timestamp > STAIRCASE_WINDOW ? block.timestamp - STAIRCASE_WINDOW : 0;
        uint256 oldestTs = type(uint256).max;
        for (uint8 i = 0; i < rollingCount; i++) {
            RollingSample memory s = rollingBuf[i];
            if (uint256(s.ts) >= cutoff && uint256(s.ts) < oldestTs) {
                oldestTs = s.ts;
                price = s.price;
                found = true;
            }
        }
    }

    function _cumulativeDriftBps(uint256 newPrice) internal view returns (uint256) {
        (uint256 anchorPrice, bool found) = _oldestSampleInWindow();
        if (!found || anchorPrice == 0) return 0;
        uint256 diff = newPrice > anchorPrice ? newPrice - anchorPrice : anchorPrice - newPrice;
        return (diff * 10_000) / anchorPrice;
    }

    // ── TWAP calculation ──────────────────────────────────────────────────────

    function _tryTWAP(PairData storage d)
        internal
        returns (uint256 price, uint256 timestamp, bool valid, uint256 weight)
    {
        (uint112 r0, uint112 r1, uint32 tsPair) = d.pair.getReserves();
        if (r0 == 0 || r1 == 0) return (0, tsPair, false, 0);
        if (block.timestamp <= d.oracleTimestampLast) return (0, tsPair, false, 0);

        uint32 elapsed = uint32(block.timestamp - uint256(d.oracleTimestampLast));

        uint112 stableReserve = d.wplsIsToken0 ? r1 : r0;
        uint256 scaledReserve = uint256(stableReserve) * (10 ** (18 - d.stableDecimals));
        if (scaledReserve < MIN_RESERVE_USD) return (0, tsPair, false, 0);

        // No spot fallback — sub-interval windows return invalid.
        if (elapsed < MIN_TWAP_INTERVAL) return (0, tsPair, false, 0);

        uint256 cumulative = d.wplsIsToken0
            ? d.pair.price0CumulativeLast()
            : d.pair.price1CumulativeLast();

        unchecked {
            uint32 delta = uint32(block.timestamp) - tsPair;
            if (delta > 0) {
                uint256 px = d.wplsIsToken0
                    ? (uint256(r1) << 112) / r0
                    : (uint256(r0) << 112) / r1;
                cumulative += px * delta;
            }
        }

        uint256 diff = cumulative - d.priceCumulativeLast;
        uint256 avg  = Math.mulDiv(diff, PRECISION, uint256(elapsed) << 112);

        d.priceCumulativeLast = cumulative;
        d.oracleTimestampLast  = uint40(block.timestamp);

        bool fresh = (block.timestamp - tsPair <= MAX_PRICE_AGE);
        return (avg, tsPair, fresh, scaledReserve);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _normalizeTo1e18(uint256 price, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return price;
        if (dec < 18)  return price * 10 ** (18 - dec);
        return price / 10 ** (dec - 18);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length == 0) return 18;
        uint8 d = abi.decode(data, (uint8));
        return (d < 6 || d > 18) ? 18 : d;
    }

    /// @notice Reserve-weighted median. Sorts prices+weights together, then
    ///         returns the price at which cumulative weight first crosses half of
    ///         total weight — so a deep pool needs proportionally fewer allies to
    ///         set the price than a thin one, and vice versa.
    function _weightedMedian(uint256[5] memory prices, uint256[5] memory weights, uint8 count)
        internal
        pure
        returns (uint256)
    {
        for (uint8 i = 1; i < count; i++) {
            uint256 keyP = prices[i];
            uint256 keyW = weights[i];
            uint8   j    = i;
            while (j > 0 && prices[j - 1] > keyP) {
                prices[j]  = prices[j - 1];
                weights[j] = weights[j - 1];
                j--;
            }
            prices[j]  = keyP;
            weights[j] = keyW;
        }

        uint256 totalWeight;
        for (uint8 i = 0; i < count; i++) totalWeight += weights[i];
        if (totalWeight == 0) return prices[count / 2]; // fallback: shouldn't happen, weights come from real reserves

        uint256 cumulative;
        for (uint8 i = 0; i < count; i++) {
            cumulative += weights[i];
            if (cumulative * 2 >= totalWeight) return prices[i];
        }
        return prices[count - 1];
    }

    function _sumValidReserves() internal view returns (uint256 total) {
        PairData[5] memory arr = [pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT];
        for (uint i = 0; i < 5; i++) {
            (uint112 r0, uint112 r1,) = arr[i].pair.getReserves();
            if (r0 == 0 || r1 == 0) continue;
            uint112 stableReserve = arr[i].wplsIsToken0 ? r1 : r0;
            uint256 scaledReserve = uint256(stableReserve) * (10 ** (18 - arr[i].stableDecimals));
            if (scaledReserve < MIN_RESERVE_USD) continue;
            total += scaledReserve;
        }
    }

    function _spotMedian() internal view returns (uint256 price, uint256 ts) {
        uint256[5] memory px;
        uint256[5] memory weights;
        uint8 count;
        PairData[5] memory arr = [pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT];

        for (uint i = 0; i < 5; i++) {
            (uint112 r0, uint112 r1, uint32 t0) = arr[i].pair.getReserves();
            if (r0 == 0 || r1 == 0) continue;

            uint112 stableReserve = arr[i].wplsIsToken0 ? r1 : r0;
            uint256 scaledReserve = uint256(stableReserve) * (10 ** (18 - arr[i].stableDecimals));
            if (scaledReserve < MIN_RESERVE_USD) continue;

            uint256 p = arr[i].wplsIsToken0
                ? (uint256(r1) * PRECISION) / r0
                : (uint256(r0) * PRECISION) / r1;
            p = _normalizeTo1e18(p, arr[i].stableDecimals);
            px[count]      = p;
            weights[count] = scaledReserve;
            count++;
            ts = t0;
        }

        // v9: require a minimum number of valid pools before trusting the median.
        if (count < MIN_VALID_POOLS) return (0, block.timestamp);
        return (_weightedMedian(px, weights, count), ts);
    }

    // ── Monitoring views ─────────────────────────────────────────────────────

    function getPriceStatus() external view returns (
        uint256 currentPrice,
        uint256 marketPrice,
        uint256 divergenceBps,
        bool    inConfirmation,
        uint256 confirmTimeRemaining,
        uint256 targetPrice,
        bool    spotWarningActive,
        bool    spotLiquidationEnabled
    ) {
        currentPrice = lastPrice;
        (marketPrice,) = _spotMedian();

        if (marketPrice > 0 && currentPrice > 0) {
            uint256 diff = marketPrice > currentPrice
                ? marketPrice - currentPrice
                : currentPrice - marketPrice;
            divergenceBps = (diff * 10_000) / currentPrice;
        }

        inConfirmation = pendingUpdate.isActive;
        targetPrice    = pendingUpdate.targetPrice;

        if (inConfirmation) {
            bool    isDown      = targetPrice < currentPrice;
            uint256 confirmTime = isDown ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
            uint256 elapsed     = block.timestamp - pendingUpdate.firstSeenTime;
            confirmTimeRemaining = elapsed < confirmTime ? confirmTime - elapsed : 0;
        }

        spotWarningActive        = spotWarningStart != 0;
        spotLiquidationEnabled   = spotWarningStart != 0 &&
                                   block.timestamp - spotWarningStart >= SPOT_CONFIRM_TIME;
    }
}
