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
import {EnumerableSetLib} from "src/libraries/EnumerableSetLib.sol";
import {IPositionManager} from "src/router/interfaces/IPositionManager.sol";

contract LiquidationHandler is BaseHandler {
    using Casting for uint256;
    using Units for uint256;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    EnumerableSetLib.Bytes32Set private positionKeys;

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
        // make sure executor is the one who updates the price
        vm.startPrank(owner);
        _updateEthPrice(_price);
        vm.stopPrank();

        uint256 availUsd = _getAvailableOi(_price * 1e30, _isLong);
        if (availUsd < 210e30) return;
        _sizeDelta = bound(_sizeDelta, 210e30, availUsd);

        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 40);
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

        bytes32 positionKey = keccak256(abi.encode(input.ticker, owner, input.isLong));

        if (!positionKeys.contains(positionKey)) {
            positionKeys.add(positionKey);
        }
    }

    /**
     * Check if any of the open positions are liquidatable after updating the prices
     * If they are liquidatable, liquidate them
     * Assert with a hook that the liquidator got the liquidation rewards and that
     * the position no longer exists.
     */
    function liquidatePostion(uint256 _seed, uint256 _price, uint256 _timeToSkip) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        _price = bound(_price, 500, 10_000);
        // make sure executor is the one who updates the price
        vm.startPrank(owner);
        _updateEthPrice(_price);
        vm.stopPrank();

        bytes32 key = _scanLiquidatablePositions(_price);

        if (key == bytes32(0)) return;

        bytes32 requestKey = keccak256(abi.encode("PRICE REQUEST"));

        address requester = priceFeed.getRequester(requestKey);

        vm.deal(requester, 0.01 ether);

        vm.prank(requester);
        positionManager.liquidatePosition(marketId, key, requestKey);

        positionKeys.remove(key);
    }

    function liquidatePositionWithPriceFeed(uint256 _seed, uint256 _price, uint256 _timeToSkip)
        external
        passTime(_timeToSkip)
    {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        _price = bound(_price, 500, 10_000);

        bytes32 key = _scanLiquidatablePositions(_price);

        if (key == bytes32(0)) return;

        meds[0] = uint64(_price);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);

        // Call setPricesAndExecutePosition
        MockPriceFeed(payable(address(priceFeed))).setPricesAndExecutePosition(
            IPositionManager(address(positionManager)),
            encodedPrices,
            new bytes(0), // empty error bytes
            ethTicker,
            marketId,
            key,
            uint48(block.timestamp),
            false // isLimit = false for liquidation
        );

        positionKeys.remove(key);
    }

    // Loop through the current positions keys and check if any of them are liquidatable.
    // As soon as a liquidatable position is discovered, return the key of the liquidatable position.
    // If none are discovered, return bytes32(0).
    function _scanLiquidatablePositions(uint256 _ethPrice) internal view returns (bytes32 liquidatableKey) {
        bytes32[] memory keys = positionKeys.values();
        for (uint256 i = 0; i < keys.length; i++) {
            bytes32 key = keys[i];
            Position.Data memory position = tradeStorage.getPosition(marketId, key);
            Execution.Prices memory prices = _constructPriceStruct(_ethPrice, position.isLong);
            if (Execution.checkIsLiquidatable(marketId, market, position, prices)) {
                return key;
            }
        }
        return bytes32(0);
    }

    function _constructPriceStruct(uint256 _ethPrice, bool _isLong)
        private
        pure
        returns (Execution.Prices memory prices)
    {
        uint256 expandedEthPrice = _ethPrice * 1e30;
        return Execution.Prices({
            indexPrice: expandedEthPrice,
            indexBaseUnit: 1e18,
            impactedPrice: expandedEthPrice,
            longMarketTokenPrice: expandedEthPrice,
            shortMarketTokenPrice: 1e30,
            priceImpactUsd: 0,
            collateralPrice: _isLong ? expandedEthPrice : 1e30,
            collateralBaseUnit: _isLong ? 1e18 : 1e6
        });
    }
}
