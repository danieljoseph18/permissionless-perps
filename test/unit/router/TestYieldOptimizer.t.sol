// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {MockYieldOptimizer} from "../../mocks/MockYieldOptimizer.sol";
import {IMarket, IVault} from "src/markets/Market.sol";
import {Router} from "src/router/Router.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {RewardTracker} from "src/rewards/RewardTracker.sol";
import {MockPriceFeed, IPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {ITradeStorage} from "src/positions/TradeStorage.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";

contract TestYieldOptimizer is Test {
    MockYieldOptimizer optimizer;
    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    FeeDistributor feeDistributor;
    RewardTracker rewardTracker;

    address USER = makeAddr("USER");
    address USER1 = makeAddr("USER1");
    address USER2 = makeAddr("USER2");

    uint256 constant INITIAL_ETH_AMOUNT = 1000 ether;
    uint256 constant INITIAL_USDC_AMOUNT = 1_000_000e6;

    address weth;
    address usdc;

    string ethTicker = "ETH:1";
    string usdcTicker = "USDC:1";
    string[] tickers;

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    MarketId[] marketIds;
    IVault[] vaults;

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

        // Create second market
        input = IMarketFactory.Input({
            indexTokenTicker: "ETH:1",
            marketTokenName: "LPT2",
            marketTokenSymbol: "LPT2",
            strategy: IPriceFeed.SecondaryStrategy({exists: false, feedId: bytes32(0)})
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);

        // Create third market
        input = IMarketFactory.Input({
            indexTokenTicker: "ETH:1",
            marketTokenName: "LPT3",
            marketTokenSymbol: "LPT3",
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
        MarketId marketId1 = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        MarketId marketId2 = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        MarketId marketId3 = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);

        vm.stopPrank();

        // Setup vaults and deposits for all markets
        IVault vault1 = market.getVault(marketId1);
        IVault vault2 = market.getVault(marketId2);
        IVault vault3 = market.getVault(marketId3);

        // Setup for first market (existing code)
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = RewardTracker(address(vault1.rewardTracker()));

        // Create deposits for all three markets
        for (uint256 i = 0; i < 3; i++) {
            MarketId marketId = i == 0 ? marketId1 : (i == 1 ? marketId2 : marketId3);

            vm.prank(OWNER);
            router.createDeposit{value: 20_000.01 ether + 1 gwei}(
                marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true
            );
            vm.prank(OWNER);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
            vm.stopPrank();
        }

        // Store all market IDs and vaults
        marketIds.push(marketId1);
        marketIds.push(marketId2);
        marketIds.push(marketId3);
        vaults.push(vault1);
        vaults.push(vault2);
        vaults.push(vault3);

        // Create a yield optimizer
        vm.prank(OWNER);
        optimizer = new MockYieldOptimizer("Yield Optimizer", "YIELD", weth, usdc, address(market));

        _;
    }

    /**
     * ================================================== Strategy Tests ==================================================
     */
    function test_initialize_with_strategies() public setUpMarkets {
        // Setup initial strategies and allocations
        uint8[] memory allocations = new uint8[](3);
        allocations[0] = 33;
        allocations[1] = 33;
        allocations[2] = 34;

        vm.startPrank(OWNER);
        optimizer.initialize(
            address(router),
            address(positionManager),
            address(priceFeed),
            0, // minDeposit
            0, // minDeposit
            0.001 ether, // executionFeePerDeposit
            vaults,
            allocations
        );
        vm.stopPrank();

        // Verify strategies were set correctly
        MockYieldOptimizer.Strategy[] memory strategies = optimizer.getStrategies();
        assertEq(strategies.length, 3);
        assertEq(strategies[0].allocation, 33);
        assertEq(strategies[1].allocation, 33);
        assertEq(strategies[2].allocation, 34);
    }

    function test_initialize_reverts_with_invalid_allocation() public setUpMarkets {
        uint8[] memory allocations = new uint8[](3);
        allocations[0] = 30;
        allocations[1] = 30;
        allocations[2] = 30; // Only adds up to 90

        vm.startPrank(OWNER);
        vm.expectRevert(MockYieldOptimizer.YieldOptimizer_InvalidAllocation.selector);
        optimizer.initialize(
            address(router), address(positionManager), address(priceFeed), 0, 0, 0.001 ether, vaults, allocations
        );
        vm.stopPrank();
    }

    /**
     * ================================================== Deposit Tests ==================================================
     */
    function test_depositing_into_optimizer() public setUpMarkets {
        // First initialize the optimizer with strategies
        _initializeOptimizer();

        vm.startPrank(OWNER);
        uint256 amount = 100_000e6;

        // Approve USDC spending
        IERC20(usdc).approve(address(optimizer), type(uint256).max);

        // Create deposit and get the deposit key
        optimizer.createDeposit{value: 0.003 ether}(usdc, amount);
        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, amount, usdc, block.timestamp, true));

        // Get the deposit request to verify the router requests were created
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        assertEq(request.requestKeys.length, 3);

        // Execute each deposit using the stored request keys
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }

        // Execute the optimizer deposit
        optimizer.executeDeposit(depositKey);

        vm.stopPrank();
    }

    function test_depositing_with_eth() public setUpMarkets {
        _initializeOptimizer();

        uint256 depositAmount = 10 ether;
        uint256 executionFee = 0.003 ether; // 0.001 ETH per strategy * 3 strategies
        uint256 initialBalance = OWNER.balance;

        vm.startPrank(OWNER);

        // Create deposit with ETH
        optimizer.createDeposit{value: depositAmount + executionFee}(address(0), depositAmount);
        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, depositAmount, address(0), block.timestamp, true));

        // Execute each deposit
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }

        // Execute the optimizer deposit
        optimizer.executeDeposit(depositKey);

        vm.stopPrank();

        // Verify shares were minted
        assertGt(optimizer.balanceOf(OWNER), 0, "No shares were minted");
        // Verify ETH was spent
        assertLt(OWNER.balance, initialBalance - depositAmount, "ETH was not spent");
    }

    function test_depositing_with_weth() public setUpMarkets {
        _initializeOptimizer();

        uint256 depositAmount = 10 ether;
        uint256 executionFee = 0.003 ether;
        uint256 initialWethBalance = IERC20(weth).balanceOf(OWNER);

        vm.startPrank(OWNER);

        // Approve WETH spending
        IERC20(weth).approve(address(optimizer), type(uint256).max);

        // Create deposit with WETH
        optimizer.createDeposit{value: executionFee}(weth, depositAmount);
        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, depositAmount, weth, block.timestamp, true));

        // Execute each deposit
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }

        // Execute the optimizer deposit
        optimizer.executeDeposit(depositKey);

        vm.stopPrank();

        // Verify shares were minted
        assertGt(optimizer.balanceOf(OWNER), 0, "No shares were minted");
        // Verify WETH was spent
        assertEq(IERC20(weth).balanceOf(OWNER), initialWethBalance - depositAmount, "WETH was not spent");
    }

    function test_deposit_reverts_with_insufficient_eth() public setUpMarkets {
        _initializeOptimizer();

        uint256 depositAmount = 10 ether;
        uint256 executionFee = 0.002 ether; // Insufficient fee (should be 0.003)

        vm.startPrank(OWNER);

        vm.expectRevert(MockYieldOptimizer.YieldOptimizer_InvalidAmountIn.selector);
        optimizer.createDeposit{value: depositAmount + executionFee}(address(0), depositAmount);

        vm.stopPrank();
    }

    function test_deposit_reverts_below_minimum() public setUpMarkets {
        // Set minimum deposits
        vm.startPrank(OWNER);
        optimizer.initialize(
            address(router),
            address(positionManager),
            address(priceFeed),
            1 ether, // minEthDeposit
            1000e6, // minUsdcDeposit
            0.001 ether,
            vaults,
            _getDefaultAllocations()
        );

        // Try to deposit below minimum ETH
        uint256 tooSmallEthDeposit = 0.5 ether;
        vm.expectRevert(MockYieldOptimizer.YieldOptimizer_InvalidAmountIn.selector);
        optimizer.createDeposit{value: tooSmallEthDeposit + 0.003 ether}(address(0), tooSmallEthDeposit);

        // Try to deposit below minimum USDC
        uint256 tooSmallUsdcDeposit = 500e6;
        IERC20(usdc).approve(address(optimizer), type(uint256).max);
        vm.expectRevert(MockYieldOptimizer.YieldOptimizer_InvalidAmountIn.selector);
        optimizer.createDeposit{value: 0.003 ether}(usdc, tooSmallUsdcDeposit);

        vm.stopPrank();
    }

    // Fails because all individual deposits fail
    function test_failed_deposits_are_refunded() public setUpMarkets {
        _initializeOptimizer();

        uint256 depositAmount = 10 ether;
        uint256 executionFee = 0.003 ether;
        uint256 initialBalance = OWNER.balance;

        vm.startPrank(OWNER);

        // Create deposit
        optimizer.createDeposit{value: depositAmount + executionFee}(address(0), depositAmount);
        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, depositAmount, address(0), block.timestamp, true));

        // Skip executing the deposits in the markets, which should cause them to fail
        skip(block.timestamp + 61); // skip 60 seconds to ensure requests expire

        // Execute the optimizer deposit (should store failed requests)
        optimizer.executeDeposit(depositKey);

        // Get failed requests before refund
        MockYieldOptimizer.FailedRequest[] memory failedRequests = optimizer.getFailedRequests(OWNER);
        assertGt(failedRequests.length, 0, "Should have failed requests");

        // Call refundFailedRequests
        optimizer.refundFailedRequests();

        console2.log("OWNER.balance", OWNER.balance);
        console2.log("initialBalance", initialBalance);
        console2.log("executionFee", executionFee);
        console2.log("Deposit amount", depositAmount);

        // Verify ETH was refunded (minus execution fees)
        assertEq(OWNER.balance, initialBalance - executionFee, "ETH was not properly refunded");

        // Verify failed requests were cleared
        failedRequests = optimizer.getFailedRequests(OWNER);
        assertEq(failedRequests.length, 0, "Failed requests should be cleared after refund");

        vm.stopPrank();
    }

    /**
     * ================================================== Withdrawal Tests ==================================================
     */
    function test_withdrawing_from_optimizer() public setUpMarkets {
        _initializeOptimizer();
        _setupInitialDeposits();

        uint256 numShares = optimizer.balanceOf(OWNER);
        uint256 usdcBalance = IERC20(usdc).balanceOf(OWNER);

        vm.startPrank(OWNER);
        optimizer.createWithdrawal{value: 0.1 ether}(usdc, numShares);

        bytes32 withdrawalKey = keccak256(abi.encodePacked(OWNER, numShares, usdc, block.timestamp, false));

        MockYieldOptimizer.OpenRequest memory withdrawalRequest = optimizer.getWithdrawalRequest(withdrawalKey);
        assertEq(withdrawalRequest.requestKeys.length, 3);

        // Execute each withdrawal using the stored request keys
        for (uint256 i = 0; i < withdrawalRequest.requestKeys.length; i++) {
            positionManager.executeWithdrawal{value: 0.01 ether}(marketIds[i], withdrawalRequest.requestKeys[i]);
        }

        // Execute the optimizer withdrawal
        optimizer.executeWithdrawal(withdrawalKey);

        vm.stopPrank();

        assertGt(IERC20(usdc).balanceOf(OWNER), usdcBalance);
    }

    /**
     * ================================================== Yield Tests ==================================================
     */
    /// @dev Will fail as _getReferencePrice will return 0
    function test_claim_yield() public setUpMarkets {
        _initializeOptimizer();
        _setupInitialDeposits();

        // Simulate some yield
        vm.startPrank(OWNER);
        optimizer.collectYield();

        (uint256 wethYield, uint256 usdcYield) = optimizer.claimYield();

        // Add assertions based on expected yield
        assertGe(wethYield + usdcYield, 0);
        vm.stopPrank();
    }

    /**
     * ================================================== Internal Helpers ==================================================
     */
    function _initializeOptimizer() internal {
        uint8[] memory allocations = new uint8[](3);
        allocations[0] = 33;
        allocations[1] = 33;
        allocations[2] = 34;

        vm.startPrank(OWNER);
        optimizer.initialize(
            address(router), address(positionManager), address(priceFeed), 0, 0, 0.001 ether, vaults, allocations
        );
        vaults[0].setIsOptimizer(address(optimizer), true);
        vm.stopPrank();
    }

    function _setupInitialDeposits() internal {
        vm.startPrank(OWNER);
        uint256 amount = 100_000e6;

        // Approve USDC spending
        IERC20(usdc).approve(address(optimizer), type(uint256).max);

        // Create deposit
        optimizer.createDeposit{value: 0.1 ether}(usdc, amount);
        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, amount, usdc, block.timestamp, true));

        // Execute deposits
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }
        optimizer.executeDeposit(depositKey);

        vm.stopPrank();
    }

    function test_deposit_fees_are_waived_for_optimizers() public setUpMarkets {
        _initializeOptimizer();

        // Setup optimizer in vault
        vm.startPrank(OWNER);
        for (uint256 i = 0; i < vaults.length; i++) {
            vaults[i].setIsOptimizer(address(optimizer), true);
        }
        vm.stopPrank();

        // Get initial accumulated fees
        uint256[] memory initialFees = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            initialFees[i] = vaults[i].shortAccumulatedFees();
        }

        // Perform deposit through optimizer
        vm.startPrank(OWNER);
        uint256 amount = 100_000e6;
        IERC20(usdc).approve(address(optimizer), type(uint256).max);
        optimizer.createDeposit{value: 0.003 ether}(usdc, amount);

        bytes32 depositKey = keccak256(abi.encodePacked(OWNER, amount, usdc, block.timestamp, true));

        // Execute deposits
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }
        optimizer.executeDeposit(depositKey);
        vm.stopPrank();

        // Verify no fees were charged
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(
                vaults[i].shortAccumulatedFees(), initialFees[i], "Fees should not increase for optimizer deposits"
            );
        }
    }

    function test_withdrawal_fees_are_waived_for_optimizers() public setUpMarkets {
        _initializeOptimizer();

        // Setup optimizer in vault and initial deposits
        vm.startPrank(OWNER);
        for (uint256 i = 0; i < vaults.length; i++) {
            vaults[i].setIsOptimizer(address(optimizer), true);
        }
        vm.stopPrank();

        _setupInitialDeposits();

        // Get initial accumulated fees
        uint256[] memory initialFees = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            initialFees[i] = vaults[i].shortAccumulatedFees();
        }

        // Perform withdrawal through optimizer
        vm.startPrank(OWNER);
        uint256 numShares = optimizer.balanceOf(OWNER);
        optimizer.createWithdrawal{value: 0.1 ether}(usdc, numShares);

        bytes32 withdrawalKey = keccak256(abi.encodePacked(OWNER, numShares, usdc, block.timestamp, false));

        // Execute withdrawals
        MockYieldOptimizer.OpenRequest memory withdrawalRequest = optimizer.getWithdrawalRequest(withdrawalKey);
        for (uint256 i = 0; i < withdrawalRequest.requestKeys.length; i++) {
            positionManager.executeWithdrawal{value: 0.01 ether}(marketIds[i], withdrawalRequest.requestKeys[i]);
        }
        optimizer.executeWithdrawal(withdrawalKey);
        vm.stopPrank();

        // Verify no fees were charged
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(
                vaults[i].shortAccumulatedFees(), initialFees[i], "Fees should not increase for optimizer withdrawals"
            );
        }
    }

    // Helper function for common allocations
    function _getDefaultAllocations() internal pure returns (uint8[] memory) {
        uint8[] memory allocations = new uint8[](3);
        allocations[0] = 33;
        allocations[1] = 33;
        allocations[2] = 34;
        return allocations;
    }

    function test_lp_token_price_remains_stable() public setUpMarkets {
        _initializeOptimizer();

        // Initial price should be $1
        assertEq(optimizer.getLpTokenPrice(), 1e30, "Initial LP token price should be $1");

        // Make multiple deposits of different sizes and tokens
        vm.startPrank(OWNER);
        IERC20(usdc).approve(address(optimizer), type(uint256).max);
        IERC20(weth).approve(address(optimizer), type(uint256).max);

        // First deposit - 100k USDC
        optimizer.createDeposit{value: 0.003 ether}(usdc, 100_000e6);
        bytes32 depositKey1 = keccak256(abi.encodePacked(OWNER, uint256(100_000e6), usdc, block.timestamp, true));
        _executeDeposit(depositKey1);

        uint256 price1 = optimizer.getLpTokenPrice();
        assertApproximatelyEqual(price1, 1e30, 0.05e30, "Price should remain within 5% after first deposit");

        // Second deposit - 50 ETH
        optimizer.createDeposit{value: 50 ether + 0.003 ether}(address(0), 50 ether);
        bytes32 depositKey2 = keccak256(abi.encodePacked(OWNER, uint256(50 ether), address(0), block.timestamp, true));
        _executeDeposit(depositKey2);

        uint256 price2 = optimizer.getLpTokenPrice();
        assertApproximatelyEqual(price2, 1e30, 0.05e30, "Price should remain within 5% after second deposit");

        // Third deposit - 250k USDC
        optimizer.createDeposit{value: 0.003 ether}(usdc, 250_000e6);
        bytes32 depositKey3 = keccak256(abi.encodePacked(OWNER, uint256(250_000e6), usdc, block.timestamp, true));
        _executeDeposit(depositKey3);

        uint256 price3 = optimizer.getLpTokenPrice();
        assertApproximatelyEqual(price3, 1e30, 0.05e30, "Price should remain within 5% after third deposit");

        vm.stopPrank();
    }

    // Helper function to execute deposits
    function _executeDeposit(bytes32 depositKey) internal {
        MockYieldOptimizer.OpenRequest memory request = optimizer.getDepositRequest(depositKey);
        for (uint256 i = 0; i < request.requestKeys.length; i++) {
            positionManager.executeDeposit{value: 0.01 ether}(marketIds[i], request.requestKeys[i]);
        }
        optimizer.executeDeposit(depositKey);
    }

    // Helper function to assert approximate equality within a percentage
    function assertApproximatelyEqual(uint256 a, uint256 b, uint256 maxDelta, string memory message) internal {
        uint256 delta = a > b ? a - b : b - a;
        if (delta > maxDelta) {
            emit log_named_string("Error", message);
            emit log_named_uint("Maximum delta", maxDelta);
            emit log_named_uint("Actual delta", delta);
            emit log_named_uint("Value a", a);
            emit log_named_uint("Value b", b);
            fail();
        }
    }
}
