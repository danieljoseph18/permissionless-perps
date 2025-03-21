// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketUtils} from "../markets/MarketUtils.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Casting} from "./Casting.sol";
import {MathUtils} from "./MathUtils.sol";
import {Pool} from "../markets/Pool.sol";
import {MarketId} from "../types/MarketId.sol";

/// @dev Library for Funding Related Calculations
library Funding {
    using Casting for *;
    using MathUtils for uint256;
    using MathUtils for int256;
    using MathUtils for int64;
    using MathUtils for int16;
    using MathUtils for uint48;

    uint256 constant PRICE_PRECISION = 1e30;
    int128 constant PRICE_UNIT = 1e30;
    int128 constant sPRICE_UNIT = 1e30;
    int64 constant sUNIT = 1e18;
    int64 constant sMAX_FUNDING_RATE = 0.0075e18; // 0.75%
    uint32 constant SECONDS_IN_DAY = 86400;

    function updateState(MarketId _id, IMarket market, Pool.Storage storage pool, int256 _sizeDelta, bool _isLong)
        internal
    {
        int256 nextSkew = _calculateNextSkew(_id, market, _sizeDelta, _isLong);

        (pool.fundingRate, pool.fundingAccruedUsd) = calculateNextFunding(_id, address(market));

        uint256 totalOpenInterest = pool.longOpenInterest + pool.shortOpenInterest;

        pool.fundingRateVelocity = getCurrentVelocity(
            address(market), nextSkew, pool.config.maxFundingVelocity, pool.config.skewScale, totalOpenInterest
        ).toInt64();
    }

    function calculateNextFunding(MarketId _id, address _market) public view returns (int64, int256) {
        IMarket market = IMarket(_market);

        (int64 fundingRate, int256 unrecordedFunding) = _getUnrecordedFundingWithRate(_id, market);

        return (fundingRate, market.getFundingAccrued(_id) + unrecordedFunding);
    }

    /**
     * @dev Returns the current funding rate given current market conditions. 18 D.P
     */
    function getCurrentFundingRate(MarketId _id, address _market) public view returns (int64) {
        IMarket market = IMarket(_market);
        // example:
        //  - fundingRate         = 0
        //  - velocity            = 0.0025
        //  - timeDelta           = 29,000s
        //  - maxFundingVelocity  = 0.025 (2.5%)
        //  - skew                = 300
        //  - skewScale           = 10,000
        //
        // currentFundingRate = fundingRate + velocity * (timeDelta / secondsInDay)
        // currentFundingRate = 0 + 0.0025 * (29,000 / 86,400)
        //                    = 0 + 0.0025 * 0.33564815
        //                    = 0.00083912
        (int64 fundingRate, int64 fundingRateVelocity) = market.getFundingRates(_id);

        int256 currentFundingRate =
            fundingRate + fundingRateVelocity.sMulWad(_getProportionalFundingElapsed(_id, market));

        // Clamp rate
        return currentFundingRate.clamp(-sMAX_FUNDING_RATE, sMAX_FUNDING_RATE).toInt64();
    }

    //  - proportionalSkew = skew / skewScale
    //  - velocity         = proportionalSkew * maxFundingVelocity
    //  - 18 D.P
    function getCurrentVelocity(
        address _market,
        int256 _skew,
        int16 _maxVelocity,
        int48 _skewScale,
        uint256 _totalOpenInterest
    ) public view returns (int256 velocity) {
        IMarket market = IMarket(_market);

        // If Skew Scale < totalOpenInterest, set it to totalOpenInterest (this represents a minimum value)
        uint256 scaledDownOi = _totalOpenInterest / PRICE_PRECISION;

        // As skewScale has 0 D.P, we can directly divide skew by skewScale to get a proportion to 30 D.P
        // e.g if skew = 300_000e30 ($300,000), and skewScale = 1_000_000 ($1,000,000)
        // proportionalSkew = 300_000e30 / 1_000_000 = 0.3e30 (0.3%)
        int256 proportionalSkew;

        if (_skewScale.toUint256() > scaledDownOi) {
            proportionalSkew = _skew / _skewScale;
        } else {
            proportionalSkew = _skew / scaledDownOi.toInt48();
        }

        if (proportionalSkew.abs() < market.FUNDING_VELOCITY_CLAMP()) {
            // If the proportional skew is less than the clamp, velocity is negligible.
            return 0;
        }

        // Bound skew between -1 and 1 (30 d.p)
        int256 pSkewBounded = proportionalSkew.clamp(-sPRICE_UNIT, sPRICE_UNIT);

        int256 maxVelocity = _maxVelocity.expandDecimals(4, 18);

        // Calculate the velocity to 18dp (proportionalSkew * maxFundingVelocity)
        velocity = pSkewBounded.mulDivSigned(maxVelocity, sPRICE_UNIT);
    }

    /**
     * =========================================== Private Functions ===========================================
     */

    /**
     * @dev Returns the proportional time elapsed since last funding (proportional by 1 day).
     * 18 D.P
     */
    function _getProportionalFundingElapsed(MarketId _id, IMarket market)
        private
        view
        returns (int256 proportionalFundingElapsed)
    {
        uint48 timeElapsed = _blockTimestamp() - market.getLastUpdate(_id);

        proportionalFundingElapsed = timeElapsed.divWad(SECONDS_IN_DAY).toInt256();
    }

    /**
     * @dev Returns the next market funding accrued value.
     */
    function _getUnrecordedFundingWithRate(MarketId _id, IMarket market)
        private
        view
        returns (int64 fundingRate, int256 unrecordedFunding)
    {
        fundingRate = getCurrentFundingRate(_id, address(market));

        (int256 storedFundingRate,) = market.getFundingRates(_id);

        // Minus sign is needed as funding flows in the opposite direction of the skew
        // Take an average of the current / prev funding rates
        int256 avgFundingRate = -storedFundingRate.avg(fundingRate);

        // Cumulative Percentage
        unrecordedFunding = avgFundingRate.mulDivSigned(_getProportionalFundingElapsed(_id, market), sUNIT);
    }

    function _calculateNextSkew(MarketId _id, IMarket market, int256 _sizeDelta, bool _isLong)
        private
        view
        returns (int256 nextSkew)
    {
        uint256 longOI = market.getOpenInterest(_id, true);
        uint256 shortOI = market.getOpenInterest(_id, false);

        if (_isLong) {
            _sizeDelta > 0 ? longOI += _sizeDelta.abs() : longOI -= _sizeDelta.abs();
        } else {
            _sizeDelta > 0 ? shortOI += _sizeDelta.abs() : shortOI -= _sizeDelta.abs();
        }

        nextSkew = longOI.diff(shortOI);
    }

    function _blockTimestamp() private view returns (uint48) {
        return uint48(block.timestamp);
    }
}
