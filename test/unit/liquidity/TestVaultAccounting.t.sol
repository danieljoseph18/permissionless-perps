// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {IVault} from "src/markets/Vault.sol";
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
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {Units} from "src/libraries/Units.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";
import {Execution} from "src/positions/Execution.sol";
import {Funding} from "src/libraries/Funding.sol";
import {Borrowing} from "src/libraries/Borrowing.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {Execution} from "src/positions/Execution.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";

contract TestVaultAccounting is Test {
    using MathUtils for uint256;
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
        priceFeed = MockPriceFeed(payable(address(contracts.priceFeed)));
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        market = contracts.market;
        tradeStorage = contracts.tradeStorage;
        tradeEngine = contracts.tradeEngine;
        feeDistributor = contracts.feeDistributor;

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
        tradeStorage = ITradeStorage(market.tradeStorage());
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

    struct TokenBalances {
        uint256 vaultBalanceBefore;
        uint256 executorBalanceBefore;
        uint256 referralStorageBalanceBefore;
        uint256 vaultBalanceAfter;
        uint256 executorBalanceAfter;
        uint256 referralStorageBalanceAfter;
    }

    struct VaultTest {
        uint256 sizeDelta;
        uint256 collateralDelta;
        uint256 leverage;
        uint256 tier;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        bytes32 key;
        address collateralToken;
        uint256 positionFee;
        uint256 feeForExecutor;
        uint256 affiliateRebate;
        bool isLong;
        bool shouldWrap;
    }

    // Request a new fuzzed postition
    // Cache the expected accounting values for each contract
    // Execute the position
    // Compare the expected values to the actual values
    function test_create_new_position_accounting(VaultTest memory _vaultTest) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 90);
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: _vaultTest.collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Cache State of the Vault
        tokenBalances.vaultBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.vaultBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Check the Vault Accounting
        // 1. Calculate afterFeeAmount and check that the marketCollateral after = before + afterFeeAmount
        // 2. Check exector balance after has increased by feeForExecutor
        // 3. Check referralStorage balance increased by affiliateReward

        // Calculate the expected market delta
        (_vaultTest.positionFee, _vaultTest.feeForExecutor) = Position.calculateFee(
            tradeEngine.tradingFee(),
            tradeEngine.feeForExecution(),
            _vaultTest.sizeDelta,
            input.collateralDelta,
            _vaultTest.collateralPrice,
            _vaultTest.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (_vaultTest.positionFee, _vaultTest.affiliateRebate,) =
            Referral.applyFeeDiscount(referralStorage, USER, _vaultTest.positionFee);

        // Market should equal --> collateral + position fee

        // Check the market balance
        assertEq(
            tokenBalances.vaultBalanceAfter,
            tokenBalances.vaultBalanceBefore + input.collateralDelta - _vaultTest.feeForExecutor
                - _vaultTest.affiliateRebate,
            "Market Balance"
        );
        // Check the executor balance
        assertEq(
            tokenBalances.executorBalanceAfter,
            tokenBalances.executorBalanceBefore + _vaultTest.feeForExecutor,
            "Executor Balance"
        );
        // Check the referralStorage balance
        assertEq(
            tokenBalances.referralStorageBalanceAfter,
            tokenBalances.referralStorageBalanceBefore + _vaultTest.affiliateRebate,
            "Referral Storage Balance"
        );
    }

    function test_increase_position_accounting(VaultTest memory _vaultTest) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 90);
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        uint256 collateralDelta;

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
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

        // Cache State of the Vault
        tokenBalances.vaultBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Create Increase Request
        if (_vaultTest.isLong) {
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, key, bytes32(0), OWNER);

        _increaseAssertions(tokenBalances, _vaultTest, collateralDelta);
    }

    function _increaseAssertions(
        TokenBalances memory tokenBalances,
        VaultTest memory _vaultTest,
        uint256 _collateralDelta
    ) private view {
        // Cache State of the Vault
        tokenBalances.vaultBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Check the Vault Accounting
        // 1. Calculate afterFeeAmount and check that the marketCollateral after = before + afterFeeAmount
        // 2. Check exector balance after has increased by feeForExecutor
        // 3. Check referralStorage balance increased by affiliateReward

        // Calculate the expected market delta
        (uint256 positionFee, uint256 feeForExecutor) = Position.calculateFee(
            tradeEngine.tradingFee(),
            tradeEngine.feeForExecution(),
            _vaultTest.sizeDelta,
            _collateralDelta,
            _vaultTest.collateralPrice,
            _vaultTest.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        uint256 affiliateRebate;
        (positionFee, affiliateRebate,) = Referral.applyFeeDiscount(referralStorage, USER, positionFee);

        // Market should equal --> collateral + position fee

        // Check the market balance
        assertEq(
            tokenBalances.vaultBalanceAfter,
            tokenBalances.vaultBalanceBefore + _collateralDelta - feeForExecutor - affiliateRebate,
            "Market Balance"
        );
        // Check the executor balance
        assertEq(
            tokenBalances.executorBalanceAfter, tokenBalances.executorBalanceBefore + feeForExecutor, "Executor Balance"
        );
        // Check the referralStorage balance
        assertEq(
            tokenBalances.referralStorageBalanceAfter,
            tokenBalances.referralStorageBalanceBefore + affiliateRebate,
            "Referral Storage Balance"
        );
    }

    function test_decrease_position_accounting(VaultTest memory _vaultTest, uint256 _decreasePercentage)
        public
        setUpMarkets
    {
        _decreasePercentage = bound(_decreasePercentage, 0.001e18, 1e18);
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 5); // low lev to prevent liquidation case
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: _vaultTest.collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        _vaultTest.key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, _vaultTest.key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.vaultBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        console2.log("Market Balance Before: ", tokenBalances.vaultBalanceBefore);
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        console2.log("Executor Balance Before: ", tokenBalances.executorBalanceBefore);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));
        console2.log("Referral Storage Balance Before: ", tokenBalances.referralStorageBalanceBefore);

        // Get the Position's collateral
        Position.Data memory position =
            tradeStorage.getPosition(marketId, keccak256(abi.encode(input.ticker, USER, input.isLong)));
        uint256 collateral = position.collateral.fromUsd(_vaultTest.collateralPrice, _vaultTest.collateralBaseUnit);

        // Create Decrease Request
        input.isIncrease = false;
        input.reverseWrap = false;
        if (_decreasePercentage < 0.95e18) {
            input.collateralDelta = collateral * _decreasePercentage / 1e18;
            input.sizeDelta = _vaultTest.sizeDelta * _decreasePercentage / 1e18;
        } else {
            input.collateralDelta = collateral;
        }
        vm.prank(USER);
        bytes32 orderKey = router.createPositionRequest{value: 0.01 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        uint256 userBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(USER);

        // Add buffer to price to ensure no liquidatables
        if (_shouldSkip(position, input.isLong ? 2990 : 3010, orderKey)) {
            return;
        }

        // Execute Request
        _vaultTest.key = tradeStorage.getOrderAtIndex(marketId, 0, false);
        vm.prank(OWNER);
        positionManager.executePosition(marketId, _vaultTest.key, bytes32(0), OWNER);

        _assertions(tokenBalances, _vaultTest, userBalanceBefore);
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

    function _assertions(TokenBalances memory tokenBalances, VaultTest memory _vaultTest, uint256 _userBalanceBefore)
        private
        view
    {
        // Cache State of the Vault
        tokenBalances.vaultBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(vault));
        console2.log("Market Balance After: ", tokenBalances.vaultBalanceAfter);
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        console2.log("Executor Balance After: ", tokenBalances.executorBalanceAfter);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));
        console2.log("Referral Storage Balance After: ", tokenBalances.referralStorageBalanceAfter);

        /**
         * Can record the total amount the balance decreased by, then use the
         * accounting to measure if it went in the right proportions to the right people.
         * E.g --> executor, referrer, user
         *
         * Need to also take into account the liquidation case
         */

        // Asset market balance has decreased
        assertLt(tokenBalances.vaultBalanceAfter, tokenBalances.vaultBalanceBefore, "Market Balance");

        uint256 totalDecrease = tokenBalances.vaultBalanceBefore - tokenBalances.vaultBalanceAfter;

        uint256 executorBalanceDelta = tokenBalances.executorBalanceAfter - tokenBalances.executorBalanceBefore;
        uint256 referralStorageBalanceDelta =
            tokenBalances.referralStorageBalanceAfter - tokenBalances.referralStorageBalanceBefore;
        uint256 userBalanceDelta = IERC20(_vaultTest.collateralToken).balanceOf(USER) - _userBalanceBefore;

        assertEq(totalDecrease, userBalanceDelta + executorBalanceDelta + referralStorageBalanceDelta, "Total Decrease");

        // Market balance should always be 0
        assertEq(IERC20(_vaultTest.collateralToken).balanceOf(address(market)), 0, "Market Balance not 0");
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
