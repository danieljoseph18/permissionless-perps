// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import {OwnableRoles} from "src/auth/OwnableRoles.sol";
import {PositionManager, IPositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {MarketFactory} from "src/factory/MarketFactory.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";

contract ReplacePositionManager is Script {
    address marketFactory;
    address market;
    address tradeStorage;
    address referralStorage;
    address priceFeed;
    address tradeEngine;
    address weth;
    address usdc;

    address payable router;

    IPositionManager oldPositionManager = IPositionManager(address(0));

    address[] rewardTrackers;

    uint256 internal constant _ROLE_1 = 1 << 1; // PositionManager

    function run() public {
        vm.startBroadcast();
        // PositionManager positionManager = new PositionManager(
        //     marketFactory, market, tradeStorage, referralStorage, priceFeed, tradeEngine, weth, usdc,
        // );

        // MarketFactory(marketFactory).updatePositionManager(address(positionManager));

        // Router(router).updateConfig(marketFactory, address(positionManager));

        // TradeEngine(tradeEngine).updateContracts(
        //     priceFeed, address(positionManager), tradeStorage, market, referralStorage
        // );

        // OwnableRoles(market).grantRoles(address(positionManager), _ROLE_1);
        // OwnableRoles(market).revokeRoles(address(oldPositionManager), _ROLE_1);

        // OwnableRoles(tradeStorage).grantRoles(address(positionManager), _ROLE_1);
        // OwnableRoles(tradeStorage).revokeRoles(address(oldPositionManager), _ROLE_1);

        // positionManager.updateGasEstimates(21000, 1 gwei, 1 gwei, 1 gwei);

        vm.stopBroadcast();
    }
}
