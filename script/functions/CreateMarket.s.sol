// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {PriceFeed, IPriceFeed} from "src/oracle/PriceFeed.sol";
import {Oracle} from "src/oracle/Oracle.sol";

contract CreateMarket is Script {
    MarketFactory public marketFactory = MarketFactory(0x700AC8E71a9C7B518ACF3c7c93e3f0284D23315b);
    PriceFeed public priceFeed = PriceFeed(payable(0x1887750E04fCC02B74897E417e0a10c2741A5E48));
    bytes32 secondaryStrategyId = bytes32(0);

    // Get Request from MarketRequested(bytes32 indexed requestKey, string indexed indexTokenTicker)

    function run() public {
        vm.startBroadcast();
        uint256 requestCost = Oracle.estimateRequestCost(address(priceFeed));

        IPriceFeed.SecondaryStrategy memory secondaryStrategy = IPriceFeed.SecondaryStrategy({
            exists: secondaryStrategyId == bytes32(0) ? false : true,
            feedId: secondaryStrategyId
        });

        IMarketFactory.Input memory input = IMarketFactory.Input({
            indexTokenTicker: "SLERF",
            marketTokenName: "SLERF-LP",
            marketTokenSymbol: "SLERF-LPT",
            strategy: secondaryStrategy
        });
        marketFactory.createNewMarket{value: requestCost}(input);
        vm.stopBroadcast();
    }
}
