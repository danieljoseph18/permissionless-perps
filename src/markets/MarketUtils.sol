// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Casting} from "../libraries/Casting.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Pool} from "./Pool.sol";
import {Units} from "../libraries/Units.sol";
import {MarketId} from "../types/MarketId.sol";

library MarketUtils {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using MathUtils for int256;
    using MathUtils for uint16;
    using Units for uint256;
    using Units for uint64;

    uint64 private constant PRECISION = 1e18;
    uint64 private constant BASE_FEE = 0.001e18; // 0.1%
    uint64 public constant FEE_SCALE = 0.008e18; // 0.8%
    uint64 private constant SHORT_CONVERSION_FACTOR = 1e18;

    uint64 private constant MAX_PNL_FACTOR = 0.45e18;
    uint64 private constant LONG_BASE_UNIT = 1e18;
    uint32 private constant SHORT_BASE_UNIT = 1e6;
    uint8 public constant MAX_ALLOCATION = 100;

    uint256 constant LONG_CONVERSION_FACTOR = 1e30;

    error MarketUtils_MaxOiExceeded();
    error MarketUtils_AmountTooSmall();
    error MarketUtils_InsufficientFreeLiquidity();
    error MarketUtils_AdlCantOccur();

    struct FeeState {
        uint256 baseFee;
        uint256 amountUsd;
        uint256 longTokenValue;
        uint256 shortTokenValue;
        bool initSkewLong;
        uint256 initSkew;
        bool updatedSkewLong;
        bool skewFlip;
        uint256 updatedSkew;
        uint256 skewDelta;
        uint256 feeAdditionUsd;
        uint256 indexFee;
    }

    /**
     * =========================================== Constructor Functions ===========================================
     */
    function constructDepositParams(MarketId marketId, IPriceFeed priceFeed, IMarket market, bytes32 _depositKey)
        internal
        view
        returns (IVault.ExecuteDeposit memory params)
    {
        params.market = market;
        params.deposit = market.getRequest(marketId, _depositKey);
        params.key = _depositKey;

        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.deposit.requestTimestamp);

        uint256 indexPrice = Oracle.getPrice(priceFeed, market.getTicker(marketId), params.deposit.requestTimestamp);

        int256 longPnl = getMarketPnl(marketId, address(market), indexPrice, true);
        int256 shortPnl = getMarketPnl(marketId, address(market), indexPrice, false);

        params.cumulativePnl = longPnl + shortPnl;

        params.vault = market.getVault(marketId);
    }

    function constructWithdrawalParams(MarketId marketId, IPriceFeed priceFeed, IMarket market, bytes32 _withdrawalKey)
        internal
        view
        returns (IVault.ExecuteWithdrawal memory params)
    {
        params.market = market;
        params.withdrawal = market.getRequest(marketId, _withdrawalKey);
        params.key = _withdrawalKey;
        params.shouldUnwrap = params.withdrawal.reverseWrap;

        (params.longPrices, params.shortPrices) = Oracle.getVaultPrices(priceFeed, params.withdrawal.requestTimestamp);

        uint256 indexPrice = Oracle.getPrice(priceFeed, market.getTicker(marketId), params.withdrawal.requestTimestamp);

        int256 longPnl = getMarketPnl(marketId, address(market), indexPrice, true);
        int256 shortPnl = getMarketPnl(marketId, address(market), indexPrice, false);

        params.cumulativePnl = longPnl + shortPnl;

        params.vault = market.getVault(marketId);
    }

    /**
     * =========================================== Core Functions ===========================================
     */
    function calculateDepositFee(
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _tokenAmount,
        bool _isLongToken
    ) internal pure returns (uint256) {
        uint256 baseFee = _tokenAmount.percentage(BASE_FEE);

        // If long or short token balance = 0 return Base Fee
        if (_longTokenBalance == 0 || _shortTokenBalance == 0) return baseFee;

        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? _tokenAmount.toUsd(_longTokenPrice, LONG_BASE_UNIT)
            : _tokenAmount.toUsd(_shortTokenPrice, SHORT_BASE_UNIT);

        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();

        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = _longTokenBalance.toUsd(_longTokenPrice, LONG_BASE_UNIT);
        uint256 shortValue = _shortTokenBalance.toUsd(_shortTokenPrice, SHORT_BASE_UNIT);

        // Don't want to disincentivise deposits on empty pool
        if (longValue == 0 && _isLongToken) return baseFee;
        if (shortValue == 0 && !_isLongToken) return baseFee;

        int256 initSkew = longValue.diff(shortValue);
        _isLongToken ? longValue += amountUsd : shortValue += amountUsd;
        int256 updatedSkew = longValue.diff(shortValue);

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // If No Flip + Skew Improved - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;

        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;

        // Calculate the relative impact on Market Skew
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue);

        // Calculate the additional fee
        uint256 feeAddition = _tokenAmount.percentage(feeFactor);

        return baseFee + feeAddition;
    }

    /// @dev - Med price used, as in the case of a full withdrawal, a spread between max / min could cause amount to be > pool value
    function calculateWithdrawalFee(
        uint256 _longPrice,
        uint256 _shortPrice,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _tokenAmount,
        bool _isLongToken
    ) internal pure returns (uint256) {
        uint256 baseFee = _tokenAmount.percentage(BASE_FEE);

        // Maximize to increase the impact on the skew
        uint256 amountUsd = _isLongToken
            ? _tokenAmount.toUsd(_longPrice, LONG_BASE_UNIT)
            : _tokenAmount.toUsd(_shortPrice, SHORT_BASE_UNIT);

        if (amountUsd == 0) revert MarketUtils_AmountTooSmall();

        // Minimize value of pool to maximise the effect on the skew
        uint256 longValue = _longTokenBalance.toUsd(_longPrice, LONG_BASE_UNIT);
        uint256 shortValue = _shortTokenBalance.toUsd(_shortPrice, SHORT_BASE_UNIT);

        int256 initSkew = longValue.diff(shortValue);
        _isLongToken ? longValue -= amountUsd : shortValue -= amountUsd;
        int256 updatedSkew = longValue.diff(shortValue);

        if (longValue + shortValue == 0) {
            // Charge the maximium possible fee for full withdrawals
            return baseFee + _tokenAmount.percentage(FEE_SCALE);
        }

        // Check for a Skew Flip
        bool skewFlip = initSkew ^ updatedSkew < 0;

        // If No Flip + Skew Improved - Charge the Base fee
        if (updatedSkew.abs() < initSkew.abs() && !skewFlip) return baseFee;

        // If Flip, charge full Skew After, else charge the delta
        uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;

        // Calculate the relative impact on Market Skew
        // Re-add amount to get the initial net pool value
        uint256 feeFactor = FEE_SCALE.percentage(negativeSkewAccrued, longValue + shortValue + amountUsd);

        // Calculate the additional fee
        uint256 feeAddition = _tokenAmount.percentage(feeFactor);

        return baseFee + feeAddition;
    }

    function calculateDepositAmounts(IVault.ExecuteDeposit memory _params)
        internal
        view
        returns (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount)
    {
        // Waive fee for optimizers
        if (IVault(address(this)).isOptimizer(_params.deposit.owner)) {
            fee = 0;
        } else {
            fee = calculateDepositFee(
                _params.longPrices.med,
                _params.shortPrices.med,
                _params.vault.longTokenBalance(),
                _params.vault.shortTokenBalance(),
                _params.deposit.amountIn,
                _params.deposit.isLongToken
            );
        }

        afterFeeAmount = _params.deposit.amountIn - fee;

        mintAmount = calculateMintAmount(
            address(_params.vault),
            _params.longPrices,
            _params.shortPrices,
            afterFeeAmount,
            _params.cumulativePnl,
            _params.deposit.isLongToken
        );
    }

    function calculateWithdrawalAmounts(IVault.ExecuteWithdrawal memory _params)
        internal
        view
        returns (uint256 tokenAmountOut, uint256 amountOut)
    {
        amountOut = calculateWithdrawalAmount(
            address(_params.vault),
            _params.longPrices,
            _params.shortPrices,
            _params.withdrawal.amountIn,
            _params.cumulativePnl,
            _params.withdrawal.isLongToken
        );

        uint256 fee;

        // Waive fee for optimizers
        if (IVault(address(this)).isOptimizer(_params.withdrawal.owner)) {
            fee = 0;
        } else {
            fee = calculateWithdrawalFee(
                _params.longPrices.med,
                _params.shortPrices.med,
                _params.vault.longTokenBalance(),
                _params.vault.shortTokenBalance(),
                amountOut,
                _params.withdrawal.isLongToken
            );
        }

        tokenAmountOut = amountOut - fee;
    }

    /// @dev - Calculate the Mint Amount to 18 decimal places
    function calculateMintAmount(
        address _vault,
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _amountIn,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 marketTokenAmount) {
        uint256 marketTokenPrice = getMarketTokenPrice(_vault, _longPrices.max, _shortPrices.max, _cumulativePnl);

        // Long divisor -> (18dp * 30dp / x dp) should = 18dp -> dp = 30
        // Short divisor -> (6dp * 30dp / x dp) should = 18dp -> dp = 18
        // Minimize the Value of the Amount In
        if (marketTokenPrice == 0) {
            marketTokenAmount = _isLongToken
                ? _amountIn.mulDiv(_longPrices.min, LONG_CONVERSION_FACTOR)
                : _amountIn.mulDiv(_shortPrices.min, SHORT_CONVERSION_FACTOR);
        } else {
            uint256 valueUsd = _isLongToken
                ? _amountIn.toUsd(_longPrices.min, LONG_BASE_UNIT)
                : _amountIn.toUsd(_shortPrices.min, SHORT_BASE_UNIT);

            // (30dp * 18dp / 30dp) = 18dp
            marketTokenAmount = valueUsd.mulDiv(PRECISION, marketTokenPrice);
        }
    }

    function calculateWithdrawalAmount(
        address _vault,
        Oracle.Prices memory _longPrices,
        Oracle.Prices memory _shortPrices,
        uint256 _marketTokenAmountIn,
        int256 _cumulativePnl,
        bool _isLongToken
    ) public view returns (uint256 tokenAmount) {
        IVault vault = IVault(_vault);

        // Minimize the AUM
        uint256 marketTokenPrice = getMarketTokenPrice(_vault, _longPrices.min, _shortPrices.min, _cumulativePnl);

        uint256 valueUsd = _marketTokenAmountIn.toUsd(marketTokenPrice, PRECISION);

        // Minimize the Value of the Amount Out
        if (_isLongToken) {
            tokenAmount = valueUsd.fromUsd(_longPrices.max, LONG_BASE_UNIT);

            uint256 poolBalance = vault.longTokenBalance();

            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        } else {
            tokenAmount = valueUsd.fromUsd(_shortPrices.max, SHORT_BASE_UNIT);

            uint256 poolBalance = vault.shortTokenBalance();

            if (tokenAmount > poolBalance) tokenAmount = poolBalance;
        }
    }

    /**
     * =========================================== Utility Functions ===========================================
     */
    function getMarketTokenPrice(
        address _vault,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        int256 _cumulativePnl
    ) public view returns (uint256 lpTokenPrice) {
        IVault vault = IVault(_vault);

        uint256 totalSupply = vault.totalSupply();

        if (totalSupply == 0) {
            lpTokenPrice = 0;
        } else {
            uint256 aum = getAum(_vault, _longTokenPrice, _shortTokenPrice, _cumulativePnl);

            lpTokenPrice = aum.divWad(totalSupply);
        }
    }

    /**
     * @dev - We don't account for collateral in longTokenBalance / shortTokenBalance,
     * so the longTokenBalance / shortTokenBalance directly reflect the AUM.
     *
     * Reserved tokens still belong to the pool, theoretically, so aren't deducted, even
     * though they can't be withdrawn by LPs.
     */
    function getAum(address _vault, uint256 _longTokenPrice, uint256 _shortTokenPrice, int256 _cumulativePnl)
        public
        view
        returns (uint256 aum)
    {
        IVault vault = IVault(_vault);

        aum += (vault.longTokenBalance()).toUsd(_longTokenPrice, LONG_BASE_UNIT);

        aum += (vault.shortTokenBalance()).toUsd(_shortTokenPrice, SHORT_BASE_UNIT);

        // Subtract any Negative Pnl
        // Unrealized Positive Pnl not added to minimize AUM
        if (_cumulativePnl < 0) aum -= _cumulativePnl.abs();
    }

    /**
     * WAEP calculation is designed to preserve a position's PNL.
     *
     * waep = (size + sizeDelta) / ((previousSize / previousPrice) + (sizeDelta / nextPrice))
     */
    function calculateWeightedAverageEntryPrice(
        uint256 _prevAverageEntryPrice,
        uint256 _prevPositionSize,
        int256 _sizeDelta,
        uint256 _indexPrice
    ) internal pure returns (uint256) {
        if (_sizeDelta <= 0) {
            // If full close, Avg Entry Price is reset to 0
            if (_sizeDelta == -_prevPositionSize.toInt256()) return 0;
            // Else, Avg Entry Price doesn't change for decrease
            else return _prevAverageEntryPrice;
        }

        // If no previous position, return the index price
        if (_prevPositionSize == 0) return _indexPrice;

        // Increasing position size
        uint256 numerator = _prevPositionSize + _sizeDelta.abs();

        uint256 denominator =
            (_prevPositionSize.divWad(_prevAverageEntryPrice)) + (_sizeDelta.abs().divWad(_indexPrice));

        uint256 newAverageEntryPrice = numerator.divWad(denominator);

        return newAverageEntryPrice;
    }

    function getCumulativeMarketPnl(MarketId _id, address _market, uint256 _indexPrice) public view returns (int256) {
        return getMarketPnl(_id, _market, _indexPrice, true) + getMarketPnl(_id, _market, _indexPrice, false);
    }

    function getMarketPnl(MarketId _id, address _market, uint256 _indexPrice, bool _isLong)
        public
        view
        returns (int256 netPnl)
    {
        IMarket market = IMarket(_market);

        uint256 openInterest = market.getOpenInterest(_id, _isLong);

        uint256 averageEntryPrice = _getAverageEntryPrice(_id, market, _isLong);

        if (openInterest == 0 || averageEntryPrice == 0) return 0;

        int256 priceDelta = _indexPrice.diff(averageEntryPrice);

        if (_isLong) {
            netPnl = priceDelta.mulDivSigned(openInterest.toInt256(), averageEntryPrice.toInt256());
        } else {
            netPnl = -priceDelta.mulDivSigned(openInterest.toInt256(), averageEntryPrice.toInt256());
        }
    }

    function getPoolBalanceUsd(IVault vault, uint256 _collateralTokenPrice, uint256 _collateralBaseUnit, bool _isLong)
        public
        view
        returns (uint256 poolUsd)
    {
        poolUsd = vault.totalAvailableLiquidity(_isLong).toUsd(_collateralTokenPrice, _collateralBaseUnit);
    }

    function validateAllocation(
        MarketId _id,
        IMarket market,
        IVault vault,
        uint256 _sizeDeltaUsd,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        bool _isLong
    ) internal view {
        uint256 availableUsd =
            getAvailableOiUsd(_id, address(market), address(vault), _indexPrice, _collateralTokenPrice, _isLong);

        if (_sizeDeltaUsd > availableUsd) revert MarketUtils_MaxOiExceeded();
    }

    function getAvailableOiUsd(
        MarketId _id,
        address _market,
        address _vault,
        uint256 _indexPrice,
        uint256 _collateralTokenPrice,
        bool _isLong
    ) public view returns (uint256 availableOi) {
        uint256 collateralBaseUnit = _isLong ? LONG_BASE_UNIT : SHORT_BASE_UNIT;

        uint256 remainingAllocationUsd =
            getPoolBalanceUsd(IVault(_vault), _collateralTokenPrice, collateralBaseUnit, _isLong);

        availableOi =
            remainingAllocationUsd - remainingAllocationUsd.percentage(_getReserveFactor(_id, IMarket(_market)));

        int256 pnl = getMarketPnl(_id, _market, _indexPrice, _isLong);

        // if the pnl is positive, subtract it from the available oi
        if (pnl > 0) {
            uint256 absPnl = pnl.abs();

            // If PNL > Available OI, set OI to 0
            if (absPnl > availableOi) availableOi = 0;
            else availableOi -= absPnl;
        }
        // no negative case, as OI hasn't been freed / realised
    }

    /// @dev Doesn't take into account current open interest, or Pnl.
    function getMaxOpenInterest(
        MarketId _id,
        IMarket market,
        IVault vault,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external view returns (uint256 maxOpenInterest) {
        uint256 totalAvailableLiquidity = vault.totalAvailableLiquidity(_isLong);

        uint256 poolAmount = totalAvailableLiquidity;

        maxOpenInterest = (poolAmount - poolAmount.percentage(_getReserveFactor(_id, market))).toUsd(
            _collateralPrice, _collateralBaseUnit
        );
    }

    /// @dev Pnl to Pool Ratio - e.g 0.45e18 = 45% / $45 profit to $100 pool.
    function getPnlFactor(
        MarketId _id,
        address _market,
        address _vault,
        uint256 _indexPrice,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) public view returns (int256 pnlFactor) {
        uint256 poolUsd = getPoolBalanceUsd(IVault(_vault), _collateralPrice, _collateralBaseUnit, _isLong);

        if (poolUsd == 0) {
            return 0;
        }

        int256 pnl = getMarketPnl(_id, _market, _indexPrice, _isLong);

        uint256 factor = pnl.abs().divWadUp(poolUsd);

        return pnl > 0 ? factor.toInt256() : factor.toInt256() * -1;
    }

    /**
     * Calculates the price at which the Pnl Factor is > 0.45 (or MAX_PNL_FACTOR).
     * Note that once this price is reached, the pnl factor may not be exceeded,
     * as the price of the collateral changes dynamically also.
     * It wouldn't be possible to account for this predictably.
     */
    function getAdlThreshold(
        MarketId _id,
        IMarket market,
        IVault vault,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal view returns (uint256 adlPrice) {
        uint256 averageEntryPrice = _getAverageEntryPrice(_id, market, _isLong);

        uint256 openInterest = market.getOpenInterest(_id, _isLong);

        uint256 poolUsd = getPoolBalanceUsd(vault, _collateralPrice, _collateralBaseUnit, _isLong);

        uint256 maxProfit = poolUsd.percentage(MAX_PNL_FACTOR);

        uint256 priceDelta = averageEntryPrice.mulDivUp(maxProfit, openInterest);

        if (_isLong) {
            // For long positions, ADL price is:
            // averageEntryPrice + (maxProfit * averageEntryPrice) / openInterest
            adlPrice = averageEntryPrice + priceDelta;
        } else {
            // For short positions, ADL price is:
            // averageEntryPrice - (maxProfit * averageEntryPrice) / openInterest
            // if price delta > average entry price, it's impossible, as price can't be 0.
            if (priceDelta > averageEntryPrice) revert MarketUtils_AdlCantOccur();
            adlPrice = averageEntryPrice - priceDelta;
        }
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function generateAssetId(string memory _ticker) internal pure returns (bytes32) {
        return keccak256(abi.encode(_ticker));
    }

    function hasSufficientLiquidity(IVault vault, uint256 _amount, bool _isLong) internal view {
        if (vault.totalAvailableLiquidity(_isLong) < _amount) {
            revert MarketUtils_InsufficientFreeLiquidity();
        }
    }

    /// @dev - Allocations are in the same order as the tickers in the market array.
    /// Allocations are a % to 0 d.p. e.g 1 = 1%
    function encodeAllocations(uint8[] memory _allocs) public pure returns (bytes memory allocations) {
        allocations = new bytes(_allocs.length);

        for (uint256 i = 0; i < _allocs.length;) {
            allocations[i] = bytes1(_allocs[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _getAverageEntryPrice(MarketId _id, IMarket market, bool _isLong) private view returns (uint256) {
        return _isLong
            ? market.getCumulatives(_id).longAverageEntryPriceUsd
            : market.getCumulatives(_id).shortAverageEntryPriceUsd;
    }

    function _getReserveFactor(MarketId _id, IMarket market) private view returns (uint256) {
        return market.getConfig(_id).reserveFactor.expandDecimals(4, 18);
    }
}
