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

contract AdlHandler is BaseHandler {
    using Casting for uint256;
    using Casting for int256;
    using Units for uint256;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using MathUtils for uint256;

    EnumerableSetLib.Bytes32Set private longKeys;
    EnumerableSetLib.Bytes32Set private shortKeys;

    bytes32 lowestEntryLongKey;
    uint256 lowestEntryLong;
    bytes32 highestEntryShortKey;
    uint256 highestEntryShort;

    uint64 private constant PRECISION = 1e18;
    uint64 private constant MAX_PNL_FACTOR = 0.45e18;
    uint64 private constant TARGET_PNL_FACTOR = 0.35e18;
    uint64 private constant MIN_PROFIT_PERCENTAGE = 0.05e18;

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

        // Price isn't being updated properly on the contract.

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

        if (input.isLong) {
            if (!longKeys.contains(positionKey)) {
                longKeys.add(positionKey);
            }

            if (_price < lowestEntryLong) {
                lowestEntryLong = _price;
                lowestEntryLongKey = positionKey;
            }
        } else {
            if (!shortKeys.contains(positionKey)) {
                shortKeys.add(positionKey);
            }

            if (_price > highestEntryShort) {
                highestEntryShort = _price;
                highestEntryShortKey = positionKey;
            }
        }
    }

    function adlMarket(uint256 _seed, uint256 _price, uint256 _timeToSkip) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        _price = bound(_price, 500, 10_000);
        // make sure executor is the one who updates the price
        vm.startPrank(owner);
        _updateEthPrice(_price);
        vm.stopPrank();

        uint256 scaledIndexPrice = _price * 1e30;

        int256 pnlFactorLong = MarketUtils.getPnlFactor(
            marketId, address(market), address(vault), scaledIndexPrice, scaledIndexPrice, 1e18, true
        );

        if (pnlFactorLong > 0 && pnlFactorLong.abs() > MAX_PNL_FACTOR) {
            Execution.Prices memory prices = _constructPriceStruct(_price, true);
            _executeLongAdl(_seed, scaledIndexPrice, pnlFactorLong, prices);
        }

        int256 pnlFactorShort =
            MarketUtils.getPnlFactor(marketId, address(market), address(vault), scaledIndexPrice, 1e30, 1e6, false);

        if (pnlFactorShort > 0 && pnlFactorShort.abs() > MAX_PNL_FACTOR) {
            Execution.Prices memory prices = _constructPriceStruct(_price, false);
            _executeShortAdl(_seed, scaledIndexPrice, pnlFactorShort, prices);
        }
    }

    function _executeLongAdl(uint256 _seed, uint256 _indexPrice, int256 _pnlFactor, Execution.Prices memory _prices)
        private
    {
        bytes32 positionKey;
        if (lowestEntryLongKey != bytes32(0)) {
            positionKey = lowestEntryLongKey;
        } else {
            // Choose a random position key based on a seed
            uint256 index = bound(_seed, 0, longKeys.length() - 1);
            positionKey = longKeys.at(index);
        }

        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        // If position not profitable, return
        if (position.weightedAvgEntryPrice >= _indexPrice) {
            return;
        }

        uint256 percentageToAdl;
        (_prices.impactedPrice, percentageToAdl) = _getImpactedPrice(position, _prices, _pnlFactor);

        uint256 totalFeesOwed = Position.getTotalFeesOwed(marketId, market, position, _prices);

        if (totalFeesOwed > position.collateral.percentage(percentageToAdl)) {
            return;
        }

        bool isLiquidatable = Execution.checkIsLiquidatableWithPriceImpact(marketId, market, position, _prices);

        if (isLiquidatable) {
            return;
        }

        bytes32 requestKey = keccak256(abi.encode("PRICE REQUEST"));

        address requester = priceFeed.getRequester(requestKey);

        vm.deal(requester, 0.01 ether);

        // Execute Long ADL
        vm.prank(requester);
        positionManager.executeAdl(marketId, requestKey, positionKey);
    }

    function _executeShortAdl(uint256 _seed, uint256 _indexPrice, int256 _pnlFactor, Execution.Prices memory _prices)
        private
    {
        bytes32 positionKey;
        if (highestEntryShortKey != bytes32(0)) {
            positionKey = highestEntryShortKey;
        } else {
            // Choose a random position key based on a seed
            uint256 index = bound(_seed, 0, shortKeys.length() - 1);
            positionKey = shortKeys.at(index);
        }

        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        // If position not profitable, return
        if (position.weightedAvgEntryPrice <= _indexPrice) {
            return;
        }

        uint256 percentageToAdl;
        (_prices.impactedPrice, percentageToAdl) = _getImpactedPrice(position, _prices, _pnlFactor);

        uint256 totalFeesOwed = Position.getTotalFeesOwed(marketId, market, position, _prices);

        if (totalFeesOwed > position.collateral.percentage(percentageToAdl)) {
            return;
        }

        bool isLiquidatable = Execution.checkIsLiquidatableWithPriceImpact(marketId, market, position, _prices);

        if (isLiquidatable) {
            return;
        }

        // if fees exceed the reduction of the position, return

        bytes32 requestKey = keccak256(abi.encode("PRICE REQUEST"));

        address requester = priceFeed.getRequester(requestKey);

        vm.deal(requester, 0.01 ether);

        // Execute Short ADL
        vm.prank(requester);
        positionManager.executeAdl(marketId, requestKey, positionKey);
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

    function _getImpactedPrice(Position.Data memory position, Execution.Prices memory _prices, int256 _pnlFactor)
        private
        view
        returns (uint256 impactedPrice, uint256 percentageToAdl)
    {
        int256 pnl = Position.getPositionPnl(
            position.size, position.weightedAvgEntryPrice, _prices.indexPrice, _prices.indexBaseUnit, position.isLong
        );

        uint256 absPnlFactor = _pnlFactor.abs();

        percentageToAdl = Position.calculateAdlPercentage(absPnlFactor, pnl, position.size);

        uint256 poolUsd =
            MarketUtils.getPoolBalanceUsd(vault, _prices.collateralPrice, _prices.collateralBaseUnit, position.isLong);

        impactedPrice = _executeAdlImpact(
            _prices.indexPrice,
            position.weightedAvgEntryPrice,
            pnl.abs().percentage(percentageToAdl),
            poolUsd,
            absPnlFactor,
            position.isLong
        );
    }

    function _executeAdlImpact(
        uint256 _indexPrice,
        uint256 _averageEntryPrice,
        uint256 _pnlBeingRealized,
        uint256 _poolUsd,
        uint256 _pnlToPoolRatio,
        bool _isLong
    ) private pure returns (uint256 impactedPrice) {
        uint256 accelerationFactor = (_pnlToPoolRatio - TARGET_PNL_FACTOR).percentage(PRECISION, TARGET_PNL_FACTOR);

        uint256 pnlImpact = _pnlBeingRealized * accelerationFactor / PRECISION;

        uint256 poolImpact = pnlImpact.percentage(PRECISION, _poolUsd);

        if (poolImpact > PRECISION) poolImpact = PRECISION;

        // Calculate the minimum profit price for the position, where profit = 5% of position (average entry price +- 5%)
        uint256 minProfitPrice = _isLong
            ? _averageEntryPrice + (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE))
            : _averageEntryPrice - (_averageEntryPrice.percentage(MIN_PROFIT_PERCENTAGE));

        uint256 priceDelta = (_indexPrice.absDiff(minProfitPrice) * poolImpact) / PRECISION;

        if (_isLong) impactedPrice = _indexPrice - priceDelta;
        else impactedPrice = _indexPrice + priceDelta;
    }
}
