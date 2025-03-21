// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {MarketId} from "../types/MarketId.sol";
import {Execution} from "../positions/Execution.sol";
import {Casting} from "../libraries/Casting.sol";

library Pool {
    using Casting for uint256;
    using Casting for int48;

    event MarketStateUpdated(string ticker, bool isLong);

    error Pool_InvalidTicker();
    error Pool_InvalidReserveFactor();
    error Pool_InvalidMaxVelocity();
    error Pool_InvalidSkewScale();
    error Pool_InvalidUpdate();
    error Pool_InvalidLeverage();

    uint8 private constant MIN_LEVERAGE = 2;
    uint16 private constant MAX_LEVERAGE = 1000; // Max 1000x leverage
    uint16 private constant MIN_RESERVE_FACTOR = 1000; // 10% reserve factor
    uint16 private constant MAX_RESERVE_FACTOR = 5000; // 50% reserve factor
    int8 private constant MIN_VELOCITY = 10; // 0.1% per day
    int16 private constant MAX_VELOCITY = 2000; // 20% per day
    int16 private constant MIN_SKEW_SCALE = 1000; // $1000
    int48 private constant MAX_SKEW_SCALE = 100_000_000_000; // $100 Bn
    uint256 private constant PRICE_PRECISION = 1e30;

    struct Input {
        uint256 amountIn;
        uint256 executionFee;
        address owner;
        uint48 requestTimestamp;
        uint40 stakeDuration;
        bool isLongToken;
        bool reverseWrap;
        bool isDeposit;
        bytes32 key;
        bytes32 priceRequestKey; // Key of the price update request
    }

    struct GlobalState {
        IVault vault;
        bool isInitialized;
        address poolOwner;
        /**
         * Maximum borrowing fee per day as a percentage.
         * The current borrowing fee will fluctuate along this scale,
         * based on the open interest to max open interest ratio.
         */
        uint256 borrowScale;
        string ticker;
        EnumerableMap.MarketMap requests;
    }

    struct Storage {
        Config config;
        Cumulatives cumulatives;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
        /**
         * The rate at which funding is accumulated.
         */
        int64 fundingRate;
        /**
         * The rate at which the funding rate is changing.
         */
        int64 fundingRateVelocity;
        /**
         * The rate at which borrowing fees are accruing for longs.
         */
        uint64 longBorrowingRate;
        /**
         * The rate at which borrowing fees are accruing for shorts.
         */
        uint64 shortBorrowingRate;
        /**
         * The last time the storage was updated.
         */
        uint48 lastUpdate;
        /**
         * The value (in USD) of total market funding accumulated.
         * Swings back and forth across 0 depending on the velocity / funding rate.
         */
        int256 fundingAccruedUsd;
        /**
         * The size of the Price impact pool.
         * Negative price impact is accumulated in the pool.
         * Positive price impact is paid out of the pool.
         * Units in USD (30 D.P).
         */
        uint256 impactPool;
    }

    struct Cumulatives {
        /**
         * The weighted average entry price of all long positions in the market.
         */
        uint256 longAverageEntryPriceUsd;
        /**
         * The weighted average entry price of all short positions in the market.
         */
        uint256 shortAverageEntryPriceUsd;
        /**
         * The value (%) of the total market borrowing fees accumulated for longs.
         */
        uint256 longCumulativeBorrowFees;
        /**
         * The value (%) of the total market borrowing fees accumulated for shorts.
         */
        uint256 shortCumulativeBorrowFees;
        /**
         * The average cumulative borrow fees at entry for long positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeLong;
        /**
         * The average cumulative borrow fees at entry for short positions in the market.
         * Used to calculate total borrow fees owed for the market.
         */
        uint256 weightedAvgCumulativeShort;
    }

    struct Config {
        /**
         * Maximum Leverage for the Market
         * Value to 0 decimal places. E.g. 5 = 5x leverage.
         */
        uint16 maxLeverage;
        /**
         * % of liquidity that CAN'T be allocated to positions
         * Reserves should be higher for more volatile markets.
         * 4 d.p precision. 2500 = 25%
         */
        uint16 reserveFactor;
        /**
         * Maximum Funding Velocity
         * Units: % Per Day
         * 4 d.p precision. 1000 = 10%
         */
        int16 maxFundingVelocity;
        /**
         * Sensitivity to Market Skew
         * Units: USD
         * No decimals --> 1_000_000 = $1,000,000
         */
        int48 skewScale;
    }

    function initialize(Storage storage pool, Config memory _config) external {
        pool.config = _config;
        pool.lastUpdate = uint48(block.timestamp);
    }

    /// @dev Needs to be external to keep bytecode size below threshold.
    /// @dev Order of operations is important, as some functions rely on others.
    /// For example, Funding relies on the open interest to calculate the skew.
    function updateState(
        MarketId _id,
        IMarket market,
        Storage storage pool,
        string calldata _ticker,
        uint256 _sizeDelta,
        Execution.Prices memory _prices,
        bool _isLong,
        bool _isIncrease
    ) external {
        if (address(this) != address(market)) revert Pool_InvalidUpdate();

        Funding.updateState(_id, market, pool, _isIncrease ? _sizeDelta.toInt256() : -_sizeDelta.toInt256(), _isLong);

        if (_sizeDelta != 0) {
            _updateWeightedAverages(
                _id,
                pool,
                market,
                _prices.impactedPrice == 0 ? _prices.indexPrice : _prices.impactedPrice, // If no price impact, set to the index price
                _isIncrease ? int256(_sizeDelta) : -int256(_sizeDelta),
                _isLong
            );

            if (_isIncrease) {
                if (_isLong) {
                    pool.longOpenInterest += _sizeDelta;
                } else {
                    pool.shortOpenInterest += _sizeDelta;
                }
            } else {
                if (_isLong) {
                    pool.longOpenInterest -= _sizeDelta;
                } else {
                    pool.shortOpenInterest -= _sizeDelta;
                }
            }
        }

        _updateBorrowState(_id, market, pool, _prices.collateralPrice, _prices.collateralBaseUnit, _isLong);

        pool.lastUpdate = uint48(block.timestamp);

        emit MarketStateUpdated(_ticker, _isLong);
    }

    /**
     * =========================================== External Functions ===========================================
     */
    function createRequest(
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        address _weth,
        uint40 _stakeDuration,
        bool _reverseWrap,
        bool _isDeposit
    ) external view returns (Pool.Input memory) {
        return Pool.Input({
            amountIn: _amountIn,
            executionFee: _executionFee,
            owner: _owner,
            requestTimestamp: uint48(block.timestamp),
            stakeDuration: _stakeDuration,
            isLongToken: _transferToken == _weth,
            reverseWrap: _reverseWrap,
            isDeposit: _isDeposit,
            key: _generateKey(_owner, _transferToken, _amountIn, _isDeposit, _priceRequestKey),
            priceRequestKey: _priceRequestKey
        });
    }

    function validateLeverage(uint16 _maxLeverage) internal pure {
        if (_maxLeverage <= MIN_LEVERAGE || _maxLeverage > MAX_LEVERAGE) {
            revert Pool_InvalidLeverage();
        }
    }

    function validateConfig(Config calldata _config, uint256 _totalOpenInterest) internal pure {
        if (_config.maxLeverage <= MIN_LEVERAGE || _config.maxLeverage > MAX_LEVERAGE) {
            revert Pool_InvalidLeverage();
        }

        if (_config.reserveFactor < MIN_RESERVE_FACTOR || _config.reserveFactor > MAX_RESERVE_FACTOR) {
            revert Pool_InvalidReserveFactor();
        }

        if (_config.maxFundingVelocity < MIN_VELOCITY || _config.maxFundingVelocity > MAX_VELOCITY) {
            revert Pool_InvalidMaxVelocity();
        }

        // skew scale should be between 1000 and 100 Bn, skew scale should also never be < totalOpenInterest
        uint256 scaledDownOi = _totalOpenInterest / PRICE_PRECISION;
        if (
            _config.skewScale < MIN_SKEW_SCALE || _config.skewScale > MAX_SKEW_SCALE
                || _config.skewScale.toUint256() < scaledDownOi
        ) {
            revert Pool_InvalidSkewScale();
        }
    }

    /**
     * ========================= Private Functions =========================
     */
    function _updateWeightedAverages(
        MarketId _id,
        Pool.Storage storage _storage,
        IMarket market,
        uint256 _priceUsd,
        int256 _sizeDeltaUsd,
        bool _isLong
    ) private {
        if (_sizeDeltaUsd == 0) return;

        if (_isLong) {
            _storage.cumulatives.longAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.longAverageEntryPriceUsd, _storage.longOpenInterest, _sizeDeltaUsd, _priceUsd
            );

            _storage.cumulatives.weightedAvgCumulativeLong =
                Borrowing.getNextAverageCumulative(_id, address(market), _sizeDeltaUsd, true);
        } else {
            _storage.cumulatives.shortAverageEntryPriceUsd = MarketUtils.calculateWeightedAverageEntryPrice(
                _storage.cumulatives.shortAverageEntryPriceUsd, _storage.shortOpenInterest, _sizeDeltaUsd, _priceUsd
            );

            _storage.cumulatives.weightedAvgCumulativeShort =
                Borrowing.getNextAverageCumulative(_id, address(market), _sizeDeltaUsd, false);
        }
    }

    function _updateBorrowState(
        MarketId _id,
        IMarket market,
        Storage storage _storage,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) private {
        Borrowing.updateState(
            _id,
            address(market),
            address(market.getVault(_id)),
            _storage,
            _collateralPrice,
            _collateralBaseUnit,
            _isLong
        );
    }

    function _generateKey(
        address _owner,
        address _tokenIn,
        uint256 _tokenAmount,
        bool _isDeposit,
        bytes32 _priceRequestKey
    ) private view returns (bytes32) {
        return keccak256(abi.encode(_owner, _tokenIn, _tokenAmount, _isDeposit, block.timestamp, _priceRequestKey));
    }
}
