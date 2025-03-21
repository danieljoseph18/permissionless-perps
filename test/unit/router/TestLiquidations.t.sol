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

contract TestLiquidations is Test {
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

    function test_positions_with_high_leverage_required_higher_maintenance_margin(
        uint256 _sizeDelta,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 1_000_000e30, 10_000_000e30);
            // 490x leverage so leverage after fees is around 1000x
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / 490, 1e18, 3000e30);
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
            _sizeDelta = bound(_sizeDelta, 1_000_000e30, 10_000_000e30);
            // 490x leverage so leverage after fees is around 1000x
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / 490, 1e6, 1e30);
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
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        skip(1);

        bytes32 positionKey = keccak256(abi.encode(input.ticker, OWNER, input.isLong));

        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        vm.startPrank(OWNER);

        uint256 entryPrice = position.weightedAvgEntryPrice / 1e30;

        // Move price so it's liquidatable
        _updateEthPrice(_isLong ? uint64(entryPrice - 5) : uint64(entryPrice + 5), OWNER);

        positionManager.liquidatePosition(marketId, positionKey, keccak256(abi.encode("PRICE REQUEST")));

        vm.stopPrank();
    }

    function test_users_are_refunded_collateral_remaining_after_liquidation(
        uint256 _sizeDelta,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 1_000_000e30, 10_000_000e30);
            // 5x leverage
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / 5, 1e18, 3000e30);
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
            _sizeDelta = bound(_sizeDelta, 1_000_000e30, 10_000_000e30);
            // 2x leverage
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / 5, 1e6, 1e30);
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
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        skip(1);

        bytes32 positionKey = keccak256(abi.encode(input.ticker, OWNER, input.isLong));

        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        vm.startPrank(USER);

        uint256 entryPrice = position.weightedAvgEntryPrice / 1e30;
        // Move price so it's liquidatable, but some collateral remains
        _updateEthPrice(_isLong ? uint64(entryPrice - 95) : uint64(entryPrice + 95), USER);

        uint256 ownerBalanceBefore = _isLong ? address(OWNER).balance : MockUSDC(usdc).balanceOf(OWNER);

        positionManager.liquidatePosition(marketId, positionKey, keccak256(abi.encode("PRICE REQUEST")));

        uint256 ownerBalanceAfter = _isLong ? WETH(weth).balanceOf(OWNER) : MockUSDC(usdc).balanceOf(OWNER);

        assertGt(ownerBalanceAfter, ownerBalanceBefore);

        vm.stopPrank();
    }

    function _updateEthPrice(uint64 _newPrice, address _requester) private {
        meds[0] = _newPrice;
        _updatePriceFeeds(_requester);
    }

    function _updatePriceFeeds(address _requester) private {
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        priceFeed.updateRequestData(keccak256(abi.encode("PRICE REQUEST")), uint48(block.timestamp), _requester);
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
