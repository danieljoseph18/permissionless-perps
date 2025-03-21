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
import {Units} from "src/libraries/Units.sol";

contract TestPositions is Test {
    using Units for uint256;

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

    function test_requesting_a_position(uint256 _sizeDelta, uint256 _leverage, bool _isLong) public setUpMarkets {
        Position.Input memory input;
        _leverage = bound(_leverage, 1, 100);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 2e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.0003e30, // 0.3%
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: true,
                triggerAbove: false
            });
            vm.prank(OWNER);
            router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            _sizeDelta = bound(_sizeDelta, 2e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.0003e30, // 0.3%
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
    }

    function test_execute_new_position(uint256 _sizeDelta, uint256 _leverage, bool _isLong, bool _shouldWrap)
        public
        setUpMarkets
    {
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
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);
    }

    function test_increasing_existing_position(
        uint256 _sizeDelta1,
        uint256 _sizeDelta2,
        uint256 _leverage1,
        uint256 _leverage2,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _leverage1 = bound(_leverage1, 2, 90);
        if (_isLong) {
            _sizeDelta1 = bound(_sizeDelta1, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta1 / _leverage1, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1,
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
            _sizeDelta1 = bound(_sizeDelta1, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta1 / _leverage1, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1, // 10x leverage
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

        // Increase Position

        _leverage2 = bound(_leverage2, 2, 90);

        if (_isLong) {
            _sizeDelta2 = bound(_sizeDelta2, 210e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = MathUtils.mulDiv(_sizeDelta2 / _leverage2, 1e18, 3000e30);
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: input.collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.prank(OWNER);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            }
        } else {
            _sizeDelta2 = bound(_sizeDelta2, 210e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = MathUtils.mulDiv(_sizeDelta2 / _leverage2, 1e6, 1e30);
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        }

        // Execute Request
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);
    }

    function test_positions_are_wiped_once_executed(
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
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        // Check Existence
        vm.expectRevert();
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
    }

    function test_executing_collateral_increase(
        uint256 _sizeDelta,
        uint256 _leverage,
        uint256 _collateralDelta,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        uint256 collateralDelta;
        _leverage = bound(_leverage, 2, 90);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
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
            collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
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

        input.sizeDelta = 0;
        input.collateralDelta = bound(_collateralDelta, 1e6, (collateralDelta * 9) / 10);

        // Increase Position
        if (_isLong && _shouldWrap) {
            vm.prank(OWNER);
            router.createPositionRequest{value: input.collateralDelta + 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        }

        // Execute Request
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);
    }

    function test_executing_collateral_decrease(uint256 _sizeDelta, uint256 _leverage, bool _isLong, bool _shouldWrap)
        public
        setUpMarkets
    {
        // Create Request
        Position.Input memory input;
        uint256 collateralDelta;
        _leverage = bound(_leverage, 2, 15);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
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
            collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
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

        // Create a decrease request
        input.sizeDelta = 0;
        // Calculate collateral delta
        input.collateralDelta = collateralDelta / 4;
        input.isIncrease = false;
        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        // Execute the request
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);
    }

    function test_decreasing_positions(uint256 _sizeDelta, bool _isLong) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        if (_isLong) {
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: 5000e30, // 4x leverage
                limitPrice: 0,
                maxSlippage: 0.03e30, // 3%
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: true,
                triggerAbove: false
            });
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.51 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: 500e6,
                sizeDelta: 5000e30, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.03e30, // 3%
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

        _sizeDelta = bound(_sizeDelta, 2e30, 5000e30);

        // Min collateral around 2e6 USDC (0.4% of position)
        // If Size Delta > 99.6% of position, set to full close
        if (_sizeDelta > 4970e30) {
            _sizeDelta = 5000e30;
        }

        // Close Position
        input.collateralDelta = 0;
        input.sizeDelta = _sizeDelta;
        input.isIncrease = false;
        vm.prank(OWNER);
        bytes32 orderKey = router.createPositionRequest{value: 0.01 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        bytes32 positionKey = keccak256(abi.encode(input.ticker, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        // Add buffer to price to ensure no liquidatables
        if (_shouldSkip(position, input.isLong ? 2990 : 3010, orderKey)) {
            return;
        }

        // Execute Request
        vm.prank(OWNER);
        positionManager.executePosition(marketId, orderKey, bytes32(0), OWNER);
    }

    function _shouldSkip(Position.Data memory position, uint256 _price, bytes32 orderKey)
        private
        view
        returns (bool shouldSkip)
    {
        // If position is liquidatable, return
        Execution.Prices memory prices = _constructPriceStruct(_price, position.isLong);
        Position.Request memory request = tradeStorage.getOrder(marketId, orderKey);
        (prices.impactedPrice,) = PriceImpact.execute(marketId, market, vault, request, prices);
        shouldSkip = Execution.checkIsLiquidatableWithPriceImpact(marketId, market, position, prices);
    }

    function test_active_positions_accumulate_fees_over_time(
        uint256 _sizeDelta1,
        uint256 _sizeDelta2,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        uint256 leverage = 2;
        if (_isLong) {
            _sizeDelta1 = bound(_sizeDelta1, 20_000e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta1 / leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1,
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
            _sizeDelta1 = bound(_sizeDelta1, 20_000e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta1 / leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1, // 10x leverage
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

        // Pass some time
        skip(1 hours);

        _updatePriceFeeds();

        // Increase Position

        if (_isLong) {
            _sizeDelta2 = bound(_sizeDelta2, 20_000e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = MathUtils.mulDiv(_sizeDelta2 / leverage, 1e18, 3000e30);
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: input.collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.prank(OWNER);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            }
        } else {
            _sizeDelta2 = bound(_sizeDelta2, 20_000e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = MathUtils.mulDiv(_sizeDelta2 / leverage, 1e6, 1e30);
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        }

        // Execute Request
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        // Pass some time
        skip(1 hours);

        // Check Fees
        int256 fundingFees = market.getFundingAccrued(marketId);
        assertNotEq(fundingFees, 0, "Funding Fees Are 0");
        uint256 borrowFees = market.getCumulativeBorrowFee(marketId, _isLong);
        assertNotEq(borrowFees, 0, "Borrow Fees Are 0");
    }

    function test_creating_stop_losses_with_new_positions(
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

        bytes32 stopLossKey =
            tradeStorage.getPosition(marketId, keccak256(abi.encode(ethTicker, OWNER, _isLong))).stopLossKey;

        // Check Stop Loss
        assertNotEq(stopLossKey, bytes32(0), "Stop Loss Key Not Set");
    }

    function test_creating_take_profits_with_new_positions(
        uint256 _sizeDelta,
        uint256 _leverage,
        uint256 _takeProfitPercentage,
        uint256 _takeProfitPrice,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 90);
        _takeProfitPercentage = bound(_takeProfitPercentage, 1, 1e18);
        _takeProfitPrice = bound(_takeProfitPrice, 1e30, 1_000_000_000_000e30);
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
                    Position.Conditionals(false, true, 0, uint64(_takeProfitPercentage), 0, _takeProfitPrice)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId,
                    input,
                    Position.Conditionals(false, true, 0, uint64(_takeProfitPercentage), 0, _takeProfitPrice)
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
                Position.Conditionals(false, true, 0, uint64(_takeProfitPercentage), 0, _takeProfitPrice)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, keccak256(abi.encode("PRICE REQUEST")), OWNER);

        bytes32 takeProfitKey =
            tradeStorage.getPosition(marketId, keccak256(abi.encode(ethTicker, OWNER, _isLong))).takeProfitKey;

        // Check Take Profit
        assertNotEq(takeProfitKey, bytes32(0), "Take Profit Key Not Set");
    }

    struct Params {
        uint256 sizeDelta;
        uint256 leverage;
        uint256 stopLossPercentage;
        uint256 takeProfitPercentage;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
        bool isLong;
        bool shouldWrap;
    }

    function test_creating_stop_loss_and_take_profit_with_new_positions(Params memory _params) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _params.leverage = bound(_params.leverage, 2, 90);
        _params.takeProfitPercentage = bound(_params.takeProfitPercentage, 1, 1e18);
        _params.stopLossPercentage = bound(_params.stopLossPercentage, 1, 1e18);
        _params.stopLossPrice = bound(_params.stopLossPrice, 1e30, 1_000_000_000_000e30);
        _params.takeProfitPrice = bound(_params.takeProfitPrice, 1e30, 1_000_000_000_000e30);
        if (_params.isLong) {
            _params.sizeDelta = bound(_params.sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_params.sizeDelta / _params.leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _params.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _params.shouldWrap,
                triggerAbove: false
            });
            if (_params.shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId,
                    input,
                    Position.Conditionals(
                        true,
                        true,
                        uint64(_params.stopLossPercentage),
                        uint64(_params.takeProfitPercentage),
                        _params.stopLossPrice,
                        _params.takeProfitPrice
                    )
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId,
                    input,
                    Position.Conditionals(
                        true,
                        true,
                        uint64(_params.stopLossPercentage),
                        uint64(_params.takeProfitPercentage),
                        _params.stopLossPrice,
                        _params.takeProfitPrice
                    )
                );
                vm.stopPrank();
            }
        } else {
            _params.sizeDelta = bound(_params.sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = MathUtils.mulDiv(_params.sizeDelta / _params.leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _params.sizeDelta, // 10x leverage
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
                Position.Conditionals(
                    true,
                    true,
                    uint64(_params.stopLossPercentage),
                    uint64(_params.takeProfitPercentage),
                    _params.stopLossPrice,
                    _params.takeProfitPrice
                )
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, keccak256(abi.encode("PRICE REQUEST")), OWNER);

        bytes32 stopLossKey =
            tradeStorage.getPosition(marketId, keccak256(abi.encode(ethTicker, OWNER, _params.isLong))).stopLossKey;

        bytes32 takeProfitKey =
            tradeStorage.getPosition(marketId, keccak256(abi.encode(ethTicker, OWNER, _params.isLong))).takeProfitKey;

        // Check Take Profit
        assertNotEq(takeProfitKey, bytes32(0), "Take Profit Key Not Set");

        // Check Stop Loss
        assertNotEq(stopLossKey, bytes32(0), "Stop Loss Key Not Set");
    }

    function test_limit_order_execution_through_mock_price_feed(
        uint256 _sizeDelta,
        uint256 _limitPrice,
        uint256 _leverage,
        bool _isLong
    ) public setUpMarkets {
        // Bound inputs
        _leverage = bound(_leverage, 2, 15);
        _limitPrice = bound(_limitPrice, 2000, 4000);
        _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);

        // Create limit order
        Position.Input memory input;
        uint256 collateralDelta;

        if (_isLong) {
            collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: _limitPrice * 1e30,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: true,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            WETH(weth).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        } else {
            collateralDelta = (_sizeDelta / _leverage).fromUsd(1e30, 1e6);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: _limitPrice * 1e30,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: true,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: true
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }

        // Get the order key
        bytes32 orderKey = tradeStorage.getOrderAtIndex(marketId, 0, true);

        // Prepare mock price data
        meds[0] = uint64(_limitPrice);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);

        // Execute the limit order through MockPriceFeed
        vm.prank(OWNER);
        priceFeed.setPricesAndExecutePosition(
            positionManager, encodedPrices, new bytes(0), ethTicker, marketId, orderKey, uint48(block.timestamp), true
        );

        // Verify the position was created
        bytes32 positionKey = keccak256(abi.encode(ethTicker, OWNER, _isLong));
        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);

        assertEq(position.size, _sizeDelta, "Position size mismatch");

        assertEq(position.isLong, _isLong, "Position direction mismatch");
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
