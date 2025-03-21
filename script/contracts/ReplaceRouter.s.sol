// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {Router} from "src/router/Router.sol";
import {Market} from "src/markets/Market.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {PriceFeed} from "src/oracle/PriceFeed.sol";
import {OwnableRoles} from "src/auth/OwnableRoles.sol";
import {MarketFactory} from "src/factory/MarketFactory.sol";
import {RewardTracker} from "src/rewards/RewardTracker.sol";
import {HelperConfig, IHelperConfig} from "../HelperConfig.s.sol";
import {MarketId} from "src/types/MarketId.sol";
import {IVault} from "src/markets/interfaces/IVault.sol";

contract ReplaceRouter is Script {
    address marketFactory = 0x777351d78378Bf5EB32E2635dc27f4493b4d8AfC;
    address market = 0xAbA7cF43aD5FCC520f449C4AdD5987394d8761C2;
    address priceFeed = 0x86D4b848eE6E72a208338772b7c2aFe91cc7ee50;
    address positionManager = 0xc8597A1444F43f06520e730f5bFa2b2754b5f6C7;

    address tradeStorage = 0x83fBFE44e8781B47B9d33Ba9d20b73E2E7A9ede9;

    address oldRouter = 0x51d70b9289D7210e21850c0EC813849994b9390E;

    uint256 internal constant _ROLE_3 = 1 << 3;

    IHelperConfig public helperConfig;

    IHelperConfig.NetworkConfig public activeNetworkConfig;
    IHelperConfig.Contracts public helperContracts;

    function run() public {
        helperConfig = new HelperConfig();

        activeNetworkConfig = helperConfig.getActiveNetworkConfig();

        helperContracts = activeNetworkConfig.contracts;

        // Get all RewardTracker addresses
        address[] memory rewardTrackers = getAllRewardTrackers();

        vm.startBroadcast();

        // Deploy new Router
        Router newRouter =
            new Router(marketFactory, market, priceFeed, helperContracts.usdc, helperContracts.weth, positionManager);

        MarketFactory(marketFactory).setRouter(address(newRouter));

        OwnableRoles(priceFeed).grantRoles(address(newRouter), _ROLE_3);
        OwnableRoles(priceFeed).revokeRoles(oldRouter, _ROLE_3);

        // Update MarketFactory with new Router
        OwnableRoles(marketFactory).grantRoles(address(newRouter), _ROLE_3);
        OwnableRoles(marketFactory).revokeRoles(oldRouter, _ROLE_3);

        // Update Market with new Router
        OwnableRoles(market).grantRoles(address(newRouter), _ROLE_3);
        OwnableRoles(market).revokeRoles(oldRouter, _ROLE_3);

        // Update TradeStorage with new Router
        OwnableRoles(tradeStorage).grantRoles(address(newRouter), _ROLE_3);
        OwnableRoles(tradeStorage).revokeRoles(oldRouter, _ROLE_3);

        for (uint256 i = 0; i < rewardTrackers.length;) {
            address rewardTracker = rewardTrackers[i];
            RewardTracker(rewardTracker).setHandler(address(newRouter), true);
            RewardTracker(rewardTracker).setHandler(oldRouter, false);
            unchecked {
                ++i;
            }
        }

        // Transfer ownership to the deployer (msg.sender)
        newRouter.transferOwnership(msg.sender);

        vm.stopBroadcast();
    }

    function getAllRewardTrackers() internal view returns (address[] memory) {
        MarketFactory factory = MarketFactory(marketFactory);
        bytes32[] memory marketIds = factory.getMarketIds();

        address[] memory trackers = new address[](marketIds.length);

        for (uint256 i = 0; i < marketIds.length; i++) {
            MarketId marketId = MarketId.wrap(marketIds[i]);
            trackers[i] = address(Market(market).getRewardTracker(marketId));
        }

        return trackers;
    }
}
