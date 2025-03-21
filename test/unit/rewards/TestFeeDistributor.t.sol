// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket, Market} from "src/markets/Market.sol";
import {IVault, Vault} from "src/markets/Vault.sol";
import {Pool} from "src/markets/Pool.sol";
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

contract TestFeeDistributor is Test {
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
        rewardTracker = RewardTracker(address(vault.rewardTracker()));
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

    modifier distributeFees() {
        // Transfer Weth and Usdc to the vault
        vm.startPrank(USER);
        deal(weth, USER, 1000 ether);
        deal(usdc, USER, 300_000_000e6);
        WETH(weth).transfer(address(vault), 1000 ether);
        IERC20(usdc).transfer(address(vault), 300_000_000e6);
        vm.stopPrank();
        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(1000 ether, true);
        vault.accumulateFees(300_000_000e6, false);
        vm.stopPrank();
        Vault(payable(address(vault))).batchWithdrawFees();
        _;
    }

    function test_withdrawing_fees_always_distributes_correctly(uint256 _ethAmount, uint256 _usdcAmount)
        public
        setUpMarkets
    {
        _ethAmount = bound(_ethAmount, 604800, 1_000_000 ether);
        _usdcAmount = bound(_usdcAmount, 604800, 1_000_000_000e6);
        vm.startPrank(USER);

        deal(weth, USER, _ethAmount);
        deal(usdc, USER, _usdcAmount);

        WETH(weth).transfer(address(vault), _ethAmount);
        IERC20(usdc).transfer(address(vault), _usdcAmount);

        vm.stopPrank();

        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(_ethAmount, true);
        vault.accumulateFees(_usdcAmount, false);
        vm.stopPrank();

        Vault(payable(address(vault))).batchWithdrawFees();

        // 80% to LPs -> tokensPerInterval should equal 80% of the amount deposited / 1 week
        (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval) =
            feeDistributor.tokensPerInterval(address(vault));
        assertApproxEqAbs(wethTokensPerInterval, MathUtils.mulDiv(_ethAmount, 0.7e18, 1e18) / 7 days, 1e18);
        assertApproxEqAbs(usdcTokensPerInterval, MathUtils.mulDiv(_usdcAmount, 0.7e18, 1e18) / 7 days, 1e6);
    }

    function test_rewards_to_be_distributed_are_accurately_tracked_on_fee_distributor(
        uint256 _ethAmount,
        uint256 _usdcAmount,
        uint256 _timeToSkip
    ) public setUpMarkets {
        _ethAmount = bound(_ethAmount, 1 ether, 1000 ether);
        _usdcAmount = bound(_usdcAmount, 1000e6, 1_000_000e6);
        _timeToSkip = bound(_timeToSkip, 1, 5200 weeks);

        vm.startPrank(USER);
        deal(weth, USER, _ethAmount);
        deal(usdc, USER, _usdcAmount);
        WETH(weth).transfer(address(vault), _ethAmount);
        IERC20(usdc).transfer(address(vault), _usdcAmount);
        vm.stopPrank();

        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(_ethAmount, true);
        vault.accumulateFees(_usdcAmount, false);
        vm.stopPrank();

        Vault(payable(address(vault))).batchWithdrawFees();

        (uint256 distributedWeth, uint256 distributedUsdc) = feeDistributor.pendingRewards(address(vault));
        assertEq(distributedWeth, 0, "Initial pending rewards should be 0");
        assertEq(distributedUsdc, 0, "Initial pending rewards should be 0");

        (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval) =
            feeDistributor.tokensPerInterval(address(vault));

        // Skip time
        skip(_timeToSkip);

        (distributedWeth, distributedUsdc) = feeDistributor.pendingRewards(address(vault));

        uint256 time;
        if (_timeToSkip > 7 days) {
            time = 7 days;
        } else {
            time = _timeToSkip;
        }

        /**
         * Distributed amounts should be tokensPerInterval * timeToSkip
         */
        assertEq(distributedWeth, wethTokensPerInterval * time, "WETH rewards after time");
        assertEq(distributedUsdc, usdcTokensPerInterval * time, "USDC rewards after time");
    }

    function test_claiming_after_seven_days_doesnt_distribute_extra(
        uint256 _ethAmount,
        uint256 _usdcAmount,
        uint256 _timeToSkip
    ) public setUpMarkets {
        _ethAmount = bound(_ethAmount, 1 ether, 1000 ether);
        _usdcAmount = bound(_usdcAmount, 1000e6, 1_000_000e6);
        _timeToSkip = bound(_timeToSkip, 7 days, 30 days);

        vm.startPrank(USER);
        deal(weth, USER, _ethAmount);
        deal(usdc, USER, _usdcAmount);
        WETH(weth).transfer(address(vault), _ethAmount);
        IERC20(usdc).transfer(address(vault), _usdcAmount);
        vm.stopPrank();

        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(_ethAmount, true);
        vault.accumulateFees(_usdcAmount, false);
        vm.stopPrank();

        Vault(payable(address(vault))).batchWithdrawFees();

        (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval) =
            feeDistributor.tokensPerInterval(address(vault));

        // Skip time
        skip(_timeToSkip);

        uint256 expectedWethReward = wethTokensPerInterval * 7 days;
        uint256 expectedUsdcReward = usdcTokensPerInterval * 7 days;

        vm.prank(address(rewardTracker));
        (uint256 actualWethReward, uint256 actualUsdcReward) = feeDistributor.distribute(address(vault));

        assertEq(actualWethReward, expectedWethReward, "WETH reward should not exceed 1 week's worth");
        assertEq(actualUsdcReward, expectedUsdcReward, "USDC reward should not exceed 1 week's worth");
    }

    function test_claiming_before_seven_days_doesnt_distribute_extra(
        uint256 _ethAmount,
        uint256 _usdcAmount,
        uint256 _secondEthAmount,
        uint256 _secondUsdcAmount,
        uint256 _firstSkip,
        uint256 _secondSkip
    ) public setUpMarkets {
        _ethAmount = bound(_ethAmount, 1 ether, 1000 ether);
        _usdcAmount = bound(_usdcAmount, 1000e6, 1_000_000e6);
        _secondEthAmount = bound(_secondEthAmount, 1 ether, 1000 ether);
        _secondUsdcAmount = bound(_secondUsdcAmount, 1000e6, 1_000_000e6);
        _firstSkip = bound(_firstSkip, 1 days, 6 days);
        _secondSkip = bound(_secondSkip, 1 days, 6 days);

        vm.startPrank(USER);
        deal(weth, USER, _ethAmount);
        deal(usdc, USER, _usdcAmount);
        WETH(weth).transfer(address(vault), _ethAmount);
        IERC20(usdc).transfer(address(vault), _usdcAmount);
        vm.stopPrank();

        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(_ethAmount, true);
        vault.accumulateFees(_usdcAmount, false);
        vm.stopPrank();

        Vault(payable(address(vault))).batchWithdrawFees();

        (uint256 initWethTokensPerInterval, uint256 initUsdcTokensPerInterval) =
            feeDistributor.tokensPerInterval(address(vault));

        // Skip time
        skip(_firstSkip);

        uint256 wethRewardBefore = (initWethTokensPerInterval * _firstSkip);
        uint256 usdcRewardBefore = (initUsdcTokensPerInterval * _firstSkip);

        // Accumulate and withdraw more fees
        vm.startPrank(USER);
        deal(weth, USER, _secondEthAmount);
        deal(usdc, USER, _secondUsdcAmount);
        WETH(weth).transfer(address(vault), _secondEthAmount);
        IERC20(usdc).transfer(address(vault), _secondUsdcAmount);
        vm.stopPrank();

        vm.startPrank(address(tradeEngine));
        vault.accumulateFees(_secondEthAmount, true);
        vault.accumulateFees(_secondUsdcAmount, false);
        vm.stopPrank();

        Vault(payable(address(vault))).batchWithdrawFees();

        (uint256 wethTokensPerIntervalAfter, uint256 usdcTokensPerIntervalAfter) =
            feeDistributor.tokensPerInterval(address(vault));

        skip(_secondSkip);

        uint256 wethRewardAfter = (wethTokensPerIntervalAfter * _secondSkip);
        uint256 usdcRewardAfter = (usdcTokensPerIntervalAfter * _secondSkip);

        uint256 expectedWethReward = wethRewardAfter + wethRewardBefore;
        uint256 expectedUsdcReward = usdcRewardAfter + usdcRewardBefore;

        vm.prank(address(rewardTracker));
        (uint256 actualWethReward, uint256 actualUsdcReward) = feeDistributor.distribute(address(vault));

        if (actualWethReward == wethRewardAfter) {
            console2.log("WETH Before Ignored");
        }
        if (actualUsdcReward == usdcRewardAfter) {
            console2.log("USDC Before Ignored");
        }

        assertEq(actualWethReward, expectedWethReward, "WETH reward should be proportional to time passed");
        assertEq(actualUsdcReward, expectedUsdcReward, "USDC reward should be proportional to time passed");
    }
}
