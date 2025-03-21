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
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {Units} from "src/libraries/Units.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {IVault} from "src/markets/interfaces/IVault.sol";

contract TestReferrals is Test {
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

    /**
     * To tests:
     *
     * - Calculations for applying a fee discount
     * - Positions accumulate affiliate rewards
     * - Affiliates can claim their rewards
     */
    function test_applying_a_referral_fee_discount(uint256 _tier, uint256 _fee) public setUpMarkets {
        _tier = bound(_tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        // get the code and make sure it was set
        (bytes32 code, address codeOwner) = referralStorage.getTraderReferralInfo(USER);
        assertEq(code, bytes32(bytes("CODE")), "Invalid Code");

        // Check the new fee and affiliate rebate values
        uint256 newFee;
        uint256 affiliateRebate;
        (newFee, affiliateRebate, codeOwner) = Referral.applyFeeDiscount(referralStorage, USER, _fee);
        // Discounts = 5, 10, 15
        // Check the new fee is correct
        uint256 discountPercentage;
        if (_tier == 0) {
            discountPercentage = 0.05e18;
        } else if (_tier == 1) {
            discountPercentage = 0.1e18;
        } else {
            discountPercentage = 0.15e18;
        }
        uint256 totalReduction = _fee.percentage(discountPercentage);
        uint256 discount = totalReduction / 2;
        assertEq(newFee, _fee - discount, "Invalid New Fee");
        // Check the affiliate rebate is correct
        assertEq(affiliateRebate, totalReduction - discount, "Invalid Rebate");
        // Check the code owner is correct
        assertEq(codeOwner, OWNER, "Invalid Code Owner");
    }

    struct ReferralCache {
        Position.Input input;
        address collateralToken;
        uint256 collateralDelta;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 discountPercentage;
        uint256 affiliateRebate;
    }

    function test_whether_positions_accumulate_affiliate_rewards(uint256 _tier, bool _isLong) public setUpMarkets {
        vm.assume(_tier < 3);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));
        // Create Request
        ReferralCache memory cache;
        if (_isLong) {
            cache.collateralToken = weth;
            cache.collateralDelta = 0.5 ether;
            cache.collateralPrice = 3000e30;
            cache.collateralBaseUnit = 1e18;
            cache.input = Position.Input({
                ticker: ethTicker,
                collateralToken: cache.collateralToken,
                collateralDelta: cache.collateralDelta,
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
            vm.prank(USER);
            router.createPositionRequest{value: 0.51 ether}(
                marketId, cache.input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            cache.collateralToken = usdc;
            cache.collateralDelta = 500e6;
            cache.collateralPrice = 1e30;
            cache.collateralBaseUnit = 1e6;
            cache.input = Position.Input({
                ticker: ethTicker,
                collateralToken: cache.collateralToken,
                collateralDelta: cache.collateralDelta,
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

            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                marketId, cache.input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        vm.prank(OWNER);
        positionManager.executePosition(marketId, tradeStorage.getOrderAtIndex(marketId, 0, false), bytes32(0), OWNER);

        // check the referral storage: a) has the correct amount of funds from the discount b) has the correct funds in storage
        uint256 discountPercentage;
        if (_tier == 0) {
            discountPercentage = 0.05e18;
        } else if (_tier == 1) {
            discountPercentage = 0.1e18;
        } else {
            discountPercentage = 0.15e18;
        }
        (uint256 fee,) = Position.calculateFee(
            tradeEngine.tradingFee(),
            tradeEngine.feeForExecution(),
            5000e30,
            cache.collateralDelta,
            cache.collateralPrice,
            cache.collateralBaseUnit
        );

        (, uint256 affiliateRebate,) = Referral.applyFeeDiscount(referralStorage, USER, fee);

        assertEq(
            IERC20(cache.collateralToken).balanceOf(address(referralStorage)),
            affiliateRebate,
            "Invalid Referral Balance"
        );

        // Check the affiliate rebate is correct
        uint256 claimableRewards = referralStorage.getClaimableAffiliateRewards(OWNER, _isLong);
        assertEq(claimableRewards, affiliateRebate, "Invalid Rebate");

        // Try claiming the rewards
        uint256 balBeforeClaim = IERC20(cache.collateralToken).balanceOf(OWNER);
        vm.prank(OWNER);
        referralStorage.claimAffiliateRewards();

        // Check storage has reset and owner has received funds
        uint256 balAfterClaim = IERC20(cache.collateralToken).balanceOf(OWNER);
        assertEq(balAfterClaim, balBeforeClaim + affiliateRebate, "Invalid Claimed Rebate");
        assertEq(referralStorage.getClaimableAffiliateRewards(OWNER, _isLong), 0, "Invalid Claimed Rebate");
    }
}
