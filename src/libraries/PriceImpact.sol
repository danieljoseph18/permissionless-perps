// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {Position} from "../positions/Position.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Casting} from "./Casting.sol";
import {Units} from "./Units.sol";
import {Execution} from "../positions/Execution.sol";
import {MathUtils} from "./MathUtils.sol";
import {MarketId} from "../types/MarketId.sol";

/**
 * @title PriceImpact Library
 *
 * The formula for price impact is:
 * priceImpactUsd = priceImpactScalar * (sizeDeltaUsd * ((initialSkew/initialTotalOi) - (updatedSkew/updatedTotalOi)) * (sizeDeltaUsd / totalAvailableLiquidity))
 * = priceImpactScalar * (sizeDeltaUsd * skewScalar * liquidityScalar)
 *
 * Impact is calculated in USD, and is capped by the impact pool.
 *
 * Instead of adding / subtracting collateral, the price of the position is manipulated accordingly, by the same percentage as the impact.
 *
 * If the impact percentage exceeds the maximum slippage specified by the user, the transaction is reverted.
 */
library PriceImpact {
    using Casting for uint256;
    using Casting for int256;
    using MathUtils for uint256;
    using MathUtils for int256;
    using Units for uint256;

    // Custom Errors
    error PriceImpact_SizeDeltaIsZero();
    error PriceImpact_InsufficientLiquidity();
    error PriceImpact_InvalidState();
    error PriceImpact_SlippageExceedsMax();
    error PriceImpact_InvalidDecrease();
    error PriceImpact_InvalidImpactedPrice();

    // Constants
    uint256 private constant PRICE_PRECISION = 1e30;
    // 1% minimum liquidity factor
    int64 private constant MIN_LIQUIDITY_FACTOR = 0.01e18;

    // Struct to hold impact state
    struct ImpactState {
        uint256 longOi;
        uint256 shortOi;
        uint256 initialTotalOi;
        uint256 updatedTotalOi;
        int256 initialSkew;
        int256 updatedSkew;
        int256 priceImpactUsd;
        int256 availableOiLong;
        int256 availableOiShort;
        int256 sizeDeltaUsd;
    }

    /**
     * @notice Executes price impact calculation and applies slippage check
     * @param _id Market identifier
     * @param market Instance of IMarket
     * @param vault Instance of IVault
     * @param _request Position request containing trade details
     * @param _prices Current price data
     * @return impactedPrice The price after impact
     * @return priceImpactUsd The calculated price impact in USD
     */
    function execute(
        MarketId _id,
        IMarket market,
        IVault vault,
        Position.Request memory _request,
        Execution.Prices memory _prices
    ) external view returns (uint256 impactedPrice, int256 priceImpactUsd) {
        if (_request.input.sizeDelta == 0) revert PriceImpact_SizeDeltaIsZero();

        // No price impact on decreases
        if (!_request.input.isIncrease) {
            return (_prices.indexPrice, 0);
        }

        ImpactState memory state = _initializeImpactState(
            _id,
            market,
            vault,
            _prices,
            _request.input.isIncrease ? _request.input.sizeDelta.toInt256() : -(_request.input.sizeDelta.toInt256())
        );

        _updateImpactState(state, _request.input.isIncrease, _request.input.sizeDelta, _request.input.isLong);

        priceImpactUsd = _computePriceImpact(state, market.priceImpactScalar(), _request.input.isLong);

        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(_id, market, priceImpactUsd);
        }

        impactedPrice =
            _calculateImpactedPrice(_request.input.sizeDelta, _prices.indexPrice, priceImpactUsd, _request.input.isLong);

        if (priceImpactUsd < 0) {
            _checkSlippage(impactedPrice, _prices.indexPrice, _request.input.maxSlippage);
        }
    }

    /**
     * @notice Estimates price impact without applying slippage check
     * @param _id Market identifier
     * @param _market Address of the market
     * @param _sizeDeltaUsd Size delta in USD
     * @param _indexPrice Current index price
     * @param _longCollateralPrice Current long collateral price
     * @param _isLong Indicates if the position is long
     * @return priceImpactUsd The calculated price impact in USD
     * @return impactedPrice The price after impact
     */
    function estimate(
        MarketId _id,
        address _market,
        address _vault,
        int256 _sizeDeltaUsd,
        uint256 _indexPrice,
        uint256 _longCollateralPrice,
        bool _isLong
    ) external view returns (int256 priceImpactUsd, uint256 impactedPrice) {
        if (_sizeDeltaUsd == 0) revert PriceImpact_SizeDeltaIsZero();

        // No price impact on decreases
        if (_sizeDeltaUsd < 0) {
            return (0, _indexPrice);
        }

        IMarket market = IMarket(_market);
        IVault vault = IVault(_vault);
        // Use estimate of 1e30 for short collateral price --> avoid STD err
        ImpactState memory state =
            _initializeImpactStateEstimate(_id, market, vault, _indexPrice, _longCollateralPrice, 1e30, _sizeDeltaUsd);

        _updateImpactStateEstimate(state, _sizeDeltaUsd, _isLong);

        priceImpactUsd = _computePriceImpact(state, market.priceImpactScalar(), _isLong);

        if (priceImpactUsd > 0) {
            priceImpactUsd = _validateImpactDelta(_id, market, priceImpactUsd);
        }

        impactedPrice = _calculateImpactedPrice(_sizeDeltaUsd.abs(), _indexPrice, priceImpactUsd, _isLong);
    }

    /**
     * @notice Initializes the impact state for execute function
     */
    function _initializeImpactState(
        MarketId _id,
        IMarket market,
        IVault vault,
        Execution.Prices memory _prices,
        int256 _sizeDelta
    ) private view returns (ImpactState memory state) {
        state.longOi = market.getOpenInterest(_id, true);
        state.shortOi = market.getOpenInterest(_id, false);

        state.sizeDeltaUsd = _sizeDelta;

        state.availableOiLong = MarketUtils.getAvailableOiUsd(
            _id, address(market), address(vault), _prices.indexPrice, _prices.longMarketTokenPrice, true
        ).toInt256();

        state.availableOiShort = MarketUtils.getAvailableOiUsd(
            _id, address(market), address(vault), _prices.indexPrice, _prices.shortMarketTokenPrice, false
        ).toInt256();

        state.initialTotalOi = state.longOi + state.shortOi;
        state.initialSkew = state.longOi.diff(state.shortOi);
    }

    /**
     * @notice Initializes the impact state for estimate function
     */
    function _initializeImpactStateEstimate(
        MarketId _id,
        IMarket market,
        IVault vault,
        uint256 _indexPrice,
        uint256 _longCollateralPrice,
        uint256 _shortCollateralPrice,
        int256 _sizeDelta
    ) private view returns (ImpactState memory state) {
        state.longOi = market.getOpenInterest(_id, true);
        state.shortOi = market.getOpenInterest(_id, false);

        state.sizeDeltaUsd = _sizeDelta;

        state.availableOiLong = MarketUtils.getAvailableOiUsd(
            _id, address(market), address(vault), _indexPrice, _longCollateralPrice, true
        ).toInt256();

        state.availableOiShort = MarketUtils.getAvailableOiUsd(
            _id, address(market), address(vault), _indexPrice, _shortCollateralPrice, false
        ).toInt256();

        state.initialTotalOi = state.longOi + state.shortOi;
        state.initialSkew = state.longOi.diff(state.shortOi);
    }

    /**
     * @notice Updates the impact state based on the request
     */
    function _updateImpactState(ImpactState memory state, bool _isIncrease, uint256 _sizeDelta, bool _isLong)
        private
        pure
    {
        if (_isIncrease) {
            if (_isLong && _sizeDelta > state.availableOiLong.toUint256()) revert PriceImpact_InsufficientLiquidity();
            if (!_isLong && _sizeDelta > state.availableOiShort.toUint256()) revert PriceImpact_InsufficientLiquidity();
            state.sizeDeltaUsd = _sizeDelta.toInt256();
            state.updatedTotalOi = state.initialTotalOi + _sizeDelta;
            _isLong ? state.longOi += _sizeDelta : state.shortOi += _sizeDelta;
        } else {
            if (_sizeDelta > state.initialTotalOi) revert PriceImpact_InvalidDecrease();
            state.sizeDeltaUsd = -int256(_sizeDelta);
            state.updatedTotalOi = state.initialTotalOi - _sizeDelta;
            _isLong ? state.longOi -= _sizeDelta : state.shortOi -= _sizeDelta;
        }
        state.updatedSkew = state.longOi.diff(state.shortOi);
    }

    /**
     * @notice Updates the impact state based on the estimate request
     */
    function _updateImpactStateEstimate(ImpactState memory state, int256 _sizeDeltaUsd, bool _isLong) private pure {
        bool isIncrease = _sizeDeltaUsd > 0;
        uint256 absDelta = _sizeDeltaUsd.abs();

        if (_isLong) {
            if (isIncrease) {
                state.updatedSkew = (state.longOi + absDelta).diff(state.shortOi);
                state.updatedTotalOi = state.initialTotalOi + absDelta;
            } else {
                state.updatedSkew = (state.longOi - absDelta).diff(state.shortOi);
                state.updatedTotalOi = state.initialTotalOi - absDelta;
            }
        } else {
            if (isIncrease) {
                state.updatedSkew = state.longOi.diff(state.shortOi + absDelta);
                state.updatedTotalOi = state.initialTotalOi + absDelta;
            } else {
                state.updatedSkew = state.longOi.diff(state.shortOi - absDelta);
                state.updatedTotalOi = state.initialTotalOi - absDelta;
            }
        }
    }

    /**
     * @notice Computes the price impact based on the updated state
     */
    function _computePriceImpact(ImpactState memory state, uint256 _priceImpactScalar, bool _isLong)
        private
        pure
        returns (int256 priceImpactUsd)
    {
        if (_skewFlipped(state.initialSkew, state.updatedSkew)) {
            // Calculate the size that leads to equilibrium (must be positive)
            int256 equilibriumSize = state.initialSkew < 0 ? state.initialSkew * -1 : state.initialSkew;

            // Determine the portion of sizeDeltaUsd up to equilibrium
            int256 sizeToEquilibrium = state.sizeDeltaUsd >= equilibriumSize ? equilibriumSize : state.sizeDeltaUsd;

            // Positive impact up to equilibrium
            int256 positiveImpact = _calculateImpact(
                sizeToEquilibrium,
                0,
                state.initialSkew,
                state.initialTotalOi,
                state.initialTotalOi + sizeToEquilibrium.abs(), // Updated total OI
                _isLong ? state.availableOiShort : state.availableOiLong,
                _priceImpactScalar
            );

            // Remaining size beyond equilibrium
            int256 remainingSize = state.sizeDeltaUsd - sizeToEquilibrium;

            // Negative impact beyond equilibrium
            int256 negativeImpact = _calculateImpact(
                remainingSize,
                // After equilibrium, skew flips direction
                state.updatedSkew,
                0, // Skew is now beyond equilibrium
                state.initialTotalOi + sizeToEquilibrium.abs(), // Updated total OI
                state.updatedTotalOi,
                _isLong ? state.availableOiLong : state.availableOiShort,
                _priceImpactScalar
            );

            priceImpactUsd = positiveImpact - negativeImpact; // Assuming negative impact reduces overall price
        } else {
            // Use the available OI based on the current skew direction
            int256 currentAvailableOi = _isLong ? state.availableOiLong : state.availableOiShort;
            priceImpactUsd = _calculateImpact(
                state.sizeDeltaUsd,
                state.updatedSkew,
                state.initialSkew,
                state.initialTotalOi,
                state.updatedTotalOi,
                currentAvailableOi,
                _priceImpactScalar
            );
        }
    }

    /**
     * @notice Determines if a skew flip has occurred
     */
    function _skewFlipped(int256 _initialSkew, int256 _updatedSkew) private pure returns (bool) {
        return (_initialSkew < 0 && _updatedSkew > 0) || (_initialSkew > 0 && _updatedSkew < 0);
    }

    /**
     * @notice Calculates the price impact in USD
     */
    function _calculateImpact(
        int256 _sizeDeltaUsd,
        int256 _updatedSkew,
        int256 _initialSkew,
        uint256 _initialTotalOi,
        uint256 _updatedTotalOi,
        int256 _availableOi,
        uint256 _priceImpactScalar
    ) private pure returns (int256 priceImpactUsd) {
        if (_updatedTotalOi == 0) return 0;

        int256 initialImbalance = _initialSkew.abs().toInt256();
        int256 updatedImbalance = _updatedSkew.abs().toInt256();

        int256 skewFactor = (_initialTotalOi == 0)
            ? MathUtils.sDivWad(updatedImbalance, _updatedTotalOi.toInt256())
            : MathUtils.sDivWad(initialImbalance, _initialTotalOi.toInt256())
                - MathUtils.sDivWad(updatedImbalance, _updatedTotalOi.toInt256());

        priceImpactUsd = MathUtils.sMulWad(_sizeDeltaUsd, skewFactor);

        int256 liquidityFactor = MathUtils.sDivWad(_sizeDeltaUsd, _availableOi);

        if (liquidityFactor < MIN_LIQUIDITY_FACTOR) {
            liquidityFactor = MIN_LIQUIDITY_FACTOR;
        }

        priceImpactUsd = MathUtils.sMulWad(priceImpactUsd, liquidityFactor);

        // Scale the price impact by the price impact scalar
        priceImpactUsd = MathUtils.sMulWad(priceImpactUsd, _priceImpactScalar.toInt256());
    }

    /**
     * @notice Calculates the impacted price based on the price impact
     */
    function _calculateImpactedPrice(uint256 _sizeDeltaUsd, uint256 _indexPrice, int256 _priceImpactUsd, bool _isLong)
        private
        pure
        returns (uint256 impactedPrice)
    {
        uint256 percentageImpact = MathUtils.divWad(_priceImpactUsd.abs(), _sizeDeltaUsd);

        uint256 impactToPrice = _indexPrice.percentage(percentageImpact);

        if (_isLong) {
            impactedPrice = (_priceImpactUsd < 0) ? _indexPrice + impactToPrice : _indexPrice - impactToPrice;
        } else {
            impactedPrice = (_priceImpactUsd < 0) ? _indexPrice - impactToPrice : _indexPrice + impactToPrice;
        }

        if (impactedPrice == 0) revert PriceImpact_InvalidImpactedPrice();
    }

    /**
     * @notice Validates the price impact does not exceed the impact pool
     */
    function _validateImpactDelta(MarketId _id, IMarket market, int256 _priceImpactUsd) private view returns (int256) {
        int256 impactPoolUsd = market.getImpactPool(_id).toInt256();
        return (_priceImpactUsd > impactPoolUsd) ? impactPoolUsd : _priceImpactUsd;
    }

    /**
     * @notice Checks if the slippage exceeds the maximum allowed
     */
    function _checkSlippage(uint256 _impactedPrice, uint256 _signedPrice, uint256 _maxSlippage) private pure {
        uint256 impactDelta = _signedPrice.absDiff(_impactedPrice);
        uint256 slippage = PRICE_PRECISION.percentage(impactDelta, _signedPrice);
        if (slippage > _maxSlippage) {
            revert PriceImpact_SlippageExceedsMax();
        }
    }
}
