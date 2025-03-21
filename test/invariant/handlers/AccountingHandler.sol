// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Router} from "src/router/Router.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {Market} from "src/markets/Market.sol";
import {Position} from "src/positions/Position.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {MarketId} from "src/types/MarketId.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {Execution} from "src/positions/Execution.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {Vault} from "src/markets/Vault.sol";
import {Casting} from "src/libraries/Casting.sol";
import {Units} from "src/libraries/Units.sol";
import {BaseHandler} from "./BaseHandler.sol";
import {IMarket} from "src/markets/interfaces/IMarket.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";

contract AccountingHandler is BaseHandler {
    using Casting for uint256;
    using Units for uint256;
    using Units for int256;

    uint256 public longPnlPaidOut;
    uint256 public shortPnlPaidOut;

    uint256 public numberOfIncreases;
    uint256 public numberOfDecreases;

    constructor(
        address _weth,
        address _usdc,
        address payable _router,
        address payable _positionManager,
        address _tradeStorage,
        address _market,
        address payable _vault,
        address _priceFeed,
        MarketId _marketId
    ) BaseHandler(_weth, _usdc, _router, _positionManager, _tradeStorage, _market, _vault, _priceFeed, _marketId) {}

    function createIncreasePosition(
        uint256 _seed,
        uint256 _price,
        uint256 _sizeDelta,
        uint256 _timeToSkip,
        uint256 _leverage,
        bool _isLong,
        bool _shouldWrap
    ) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        _price = bound(_price, 500, 10_000);
        _updateEthPrice(_price);

        uint256 availUsd = _getAvailableOi(_price * 1e30, _isLong);
        if (availUsd < 210e30) return;
        _sizeDelta = bound(_sizeDelta, 210e30, availUsd);

        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 90);
        bytes32 key;
        if (_isLong) {
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, (_price * 1e30));
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                if (collateralDelta > owner.balance) return;
                vm.prank(owner);
                key = router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                if (collateralDelta > WETH(weth).balanceOf(owner)) return;
                vm.startPrank(owner);
                WETH(weth).approve(address(router), type(uint256).max);
                key = router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });
            if (collateralDelta > MockUSDC(usdc).balanceOf(owner)) return;
            vm.startPrank(owner);
            MockUSDC(usdc).approve(address(router), type(uint256).max);

            key = router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        vm.prank(owner);
        positionManager.executePosition(marketId, key, bytes32(0), owner);

        numberOfIncreases++;
    }

    /**
     * For Decrease:
     * 1. Position should still be valid after (collateral > 2e30, lev 1-100)
     * 2. Collateral delta should be enough to cover fees
     */
    function createDecreasePosition(
        uint256 _seed,
        uint256 _timeToSkip,
        uint256 _price,
        uint256 _decreasePercentage,
        bool _isLong
    ) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        Position.Data memory position =
            tradeStorage.getPosition(marketId, Position.generateKey(ethTicker, owner, _isLong));

        // Check if position exists
        if (position.size == 0) return;

        _price = bound(_price, 500, 10_000);
        _updateEthPrice(_price);

        _decreasePercentage = bound(_decreasePercentage, 0.01e18, 1e18);

        uint256 sizeDelta = position.size.percentage(_decreasePercentage);

        // Get total fees owed by the position
        uint256 totalFees = _getTotalFeesOwed(owner, _isLong);

        // Skip the case where PNL exceeds the available payout
        if (_getPnl(position, sizeDelta) > _getFreeLiquidityWithBuffer(_isLong).toInt256()) return;

        // Full decrease if size after decrease is less than 2e30 or fees exceed collateral delta
        if (position.size - sizeDelta < 2e30 || totalFees >= position.collateral.percentage(_decreasePercentage)) {
            sizeDelta = position.size;
        }

        Position.Input memory input = Position.Input({
            ticker: ethTicker,
            collateralToken: _isLong ? weth : usdc,
            collateralDelta: 0,
            sizeDelta: sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.3e30,
            executionFee: 0.01 ether,
            isLong: _isLong,
            isLimit: false,
            isIncrease: false,
            reverseWrap: false,
            triggerAbove: false
        });

        vm.prank(owner);
        bytes32 orderKey = router.createPositionRequest{value: 0.01 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        // Execute Request
        vm.prank(owner);
        try positionManager.executePosition(marketId, orderKey, bytes32(0), owner) {
            numberOfDecreases++;
            // Update PnL payout if the execution was successful
            int256 realizedPnl = _getPnl(position, sizeDelta);
            if (realizedPnl > 0) {
                _updatePnlPaidOut(_isLong, uint256(realizedPnl));
            }
            int256 fundingFees = _getFundingFeesOwed(
                sizeDelta,
                position.fundingParams.lastFundingAccrued,
                _price, // collateral price
                _isLong
            );
            if (fundingFees > 0) {
                _updatePnlPaidOut(_isLong, uint256(fundingFees));
            }
        } catch {
            // Execution failed, do nothing
        }
    }

    /**
     * =================================== Getters ===================================
     */
    function getLongBalance() public view returns (uint256) {
        return IERC20(weth).balanceOf(address(vault));
    }

    function getShortBalance() public view returns (uint256) {
        return IERC20(usdc).balanceOf(address(vault));
    }

    function getLongTokenBalance() public view returns (uint256) {
        return vault.longTokenBalance();
    }

    function getShortTokenBalance() public view returns (uint256) {
        return vault.shortTokenBalance();
    }

    function getLongAccumulatedFees() public view returns (uint256) {
        return vault.longAccumulatedFees();
    }

    function getShortAccumulatedFees() public view returns (uint256) {
        return vault.shortAccumulatedFees();
    }

    function getLongCollateral() public view returns (uint256) {
        return vault.longCollateral();
    }

    function getShortCollateral() public view returns (uint256) {
        return vault.shortCollateral();
    }

    function getLongPnlPaidOut() public view returns (uint256) {
        return longPnlPaidOut;
    }

    function getShortPnlPaidOut() public view returns (uint256) {
        return shortPnlPaidOut;
    }

    /**
     * =================================== Internal Functions ===================================
     */
    function _getTotalFeesOwed(address _owner, bool _isLong) private view returns (uint256) {
        bytes32 positionKey = Position.generateKey(ethTicker, _owner, _isLong);
        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);
        uint256 indexPrice = uint256(meds[0]) * (1e30);

        Execution.Prices memory prices;
        prices.indexPrice = indexPrice;
        prices.indexBaseUnit = 1e18;
        prices.impactedPrice = indexPrice;
        prices.longMarketTokenPrice = indexPrice;
        prices.shortMarketTokenPrice = 1e30;
        prices.priceImpactUsd = 0;
        prices.collateralPrice = _isLong ? indexPrice : 1e30;
        prices.collateralBaseUnit = _isLong ? 1e18 : 1e6;

        return Position.getTotalFeesOwedUsd(marketId, market, position);
    }

    function _getPnl(Position.Data memory _position, uint256 _sizeDelta) private view returns (int256) {
        uint256 indexPrice = uint256(meds[0]) * 1e30;
        return Position.getRealizedPnl(
            _position.size,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            indexPrice,
            1e18,
            indexPrice,
            1e18,
            _position.isLong
        );
    }

    function _getFundingFeesOwed(uint256 _sizeDelta, int256 _entryFundingAccrued, uint256 _price, bool _isLong)
        public
        view
        returns (int256)
    {
        uint256 collateralPrice = _isLong ? _price * 1e30 : 1e30;

        (int256 fundingFeeUsd,) =
            Position.getFundingFeeDelta(marketId, IMarket(address(market)), _sizeDelta, _entryFundingAccrued);

        uint256 collateralBaseUnit = _isLong ? 1e18 : 1e6;

        int256 fundingFeeCollateral = fundingFeeUsd < 0
            ? -fundingFeeUsd.fromUsdSigned(collateralPrice, collateralBaseUnit).toInt256()
            : fundingFeeUsd.fromUsdSigned(collateralPrice, collateralBaseUnit).toInt256();

        return fundingFeeCollateral;
    }

    function _updatePnlPaidOut(bool _isLong, uint256 _amount) internal {
        if (_isLong) {
            longPnlPaidOut += _amount;
        } else {
            shortPnlPaidOut += _amount;
        }
    }

    function _getFreeLiquidityWithBuffer(bool _isLong) private view returns (uint256) {
        uint256 freeLiquidity = vault.totalAvailableLiquidity(_isLong);
        // 40% buffer
        return (freeLiquidity * 6) / 10;
    }
}
