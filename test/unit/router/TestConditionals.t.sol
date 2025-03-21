// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {WETH} from "src/tokens/WETH.sol";
import {Oracle} from "src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {RewardTracker} from "src/rewards/RewardTracker.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {IVault} from "src/markets/Vault.sol";
import {Execution} from "src/positions/Execution.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";

contract TestConditionals is Test {
    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
    FeeDistributor feeDistributor;
    RewardTracker rewardTracker;

    address weth;
    address usdc;
    address link;

    MarketId marketId;

    string ethTicker = "ETH:1";
    string usdcTicker = "USDC:1";
    string[] tickers;

    address USER = makeAddr("USER");
    address USER1 = makeAddr("USER1");
    address USER2 = makeAddr("USER2");

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        marketFactory = contracts.marketFactory;
        vm.label(address(marketFactory), "marketFactory");

        priceFeed = MockPriceFeed(payable(address(contracts.priceFeed)));
        vm.label(address(priceFeed), "priceFeed");

        referralStorage = contracts.referralStorage;
        vm.label(address(referralStorage), "referralStorage");

        positionManager = contracts.positionManager;
        vm.label(address(positionManager), "positionManager");

        router = contracts.router;
        vm.label(address(router), "router");

        market = contracts.market;
        vm.label(address(market), "market");

        tradeStorage = contracts.tradeStorage;
        vm.label(address(tradeStorage), "tradeStorage");

        tradeEngine = contracts.tradeEngine;
        vm.label(address(tradeEngine), "tradeEngine");

        feeDistributor = contracts.feeDistributor;
        vm.label(address(feeDistributor), "feeDistributor");

        OWNER = contracts.owner;
        (weth, usdc,,,) = deploy.helperContracts();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 2_000_000 ether);
        console2.log("USDC: ", usdc);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 2_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.deal(USER1, 2_000_000 ether);
        MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
        vm.deal(USER2, 2_000_000 ether);
        MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
        vm.prank(USER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER1);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER2);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        IMarketFactory.Input memory input = IMarketFactory.Input({
            indexTokenTicker: "ETH:1",
            marketTokenName: "LPT",
            marketTokenSymbol: "LPT",
            strategy: IPriceFeed.SecondaryStrategy({exists: false, feedId: bytes32(0)})
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);

        vm.stopPrank();
        vault = market.getVault(marketId);
        vm.label(address(vault), "vault");
        tradeStorage = ITradeStorage(market.tradeStorage());
        vm.label(address(tradeStorage), "tradeStorage");
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        vm.stopPrank();
        _;
    }

    function test_creating_simultaneous_conditionals_then_cancelling_the_original_cancels_all_of_them(
        uint256 _sizeDelta,
        uint256 _leverage,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 90);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
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
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
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

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId,
                input,
                Position.Conditionals(true, true, 1e18, 1e18, _isLong ? 2000e30 : 5000e30, _isLong ? 5000e30 : 2000e30)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);

        // Get the order to get the conditional keys
        Position.Request memory originalRequest = tradeStorage.getOrder(marketId, key);

        skip(tradeStorage.minCancellationTime() + 1);

        bytes32 requestKey = keccak256(abi.encode("PRICE REQUEST"));
        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(IPriceFeed.fullfillmentAttempted.selector, requestKey),
            abi.encode(true)
        );

        vm.prank(OWNER);
        positionManager.cancelOrderRequest(marketId, key, false);

        // Check that the original order, and the originalRequest.stopLossKey and originalRequest.takeProfitKey are all cancelled
        assertEq(tradeStorage.getOrder(marketId, key).user, address(0));
        assertEq(tradeStorage.getOrder(marketId, originalRequest.stopLossKey).user, address(0));
        assertEq(tradeStorage.getOrder(marketId, originalRequest.takeProfitKey).user, address(0));
    }

    function test_cancelling_a_stop_loss_or_take_profit_cancels_the_associated_position_key(
        uint256 _sizeDelta,
        uint256 _leverage,
        uint256 _stopLossPercentage,
        uint256 _stopLossPrice,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 90);
        _stopLossPercentage = bound(_stopLossPercentage, 1, 1e18);
        _stopLossPrice = bound(_stopLossPrice, 1e30, 1_000_000_000_000e30);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
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
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId,
                    input,
                    Position.Conditionals(true, false, uint64(_stopLossPercentage), 0, _stopLossPrice, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId,
                    input,
                    Position.Conditionals(true, false, uint64(_stopLossPercentage), 0, _stopLossPrice, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
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

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(true, false, uint64(_stopLossPercentage), 0, _stopLossPrice, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, keccak256(abi.encode("PRICE REQUEST")), OWNER);

        bytes32 positionKey = keccak256(abi.encode(ethTicker, OWNER, _isLong));

        bytes32 stopLossKey = tradeStorage.getPosition(marketId, positionKey).stopLossKey;

        // Check Stop Loss
        assertNotEq(stopLossKey, bytes32(0), "Stop Loss Key Not Set");

        skip(tradeStorage.minCancellationTime() + 1);

        vm.prank(OWNER);
        positionManager.cancelOrderRequest(marketId, stopLossKey, true);

        // Check that the stop loss key is now 0
        assertEq(tradeStorage.getPosition(marketId, positionKey).stopLossKey, bytes32(0));
    }

    function _updatePriceFeeds() private {
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
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
