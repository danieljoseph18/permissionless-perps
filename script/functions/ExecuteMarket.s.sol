// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MarketFactory} from "src/factory/MarketFactory.sol";

contract ExecuteMarket is Script {
    MarketFactory public marketFactory = MarketFactory(0x700AC8E71a9C7B518ACF3c7c93e3f0284D23315b);

    function run() public {
        bytes32[] memory requestKeys = marketFactory.getRequestKeys();
        bytes32 requestKey = requestKeys[requestKeys.length - 1];
        vm.broadcast();
        marketFactory.executeMarketRequest(requestKey);
    }
}
