// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId, MarketIdLibrary} from "src/types/MarketId.sol";

contract CancelMarketRequest is Script {
    PositionManager positionManager = PositionManager(payable(0xdF1f52F5020DEaF52C52B00367c63928771E7D71));
    MarketId marketId = MarketId.wrap(0x69b9cda3342215535520e6b157ca90560845ae7d1e75fa59beebef34a49118ab);
    // Replace with Request Key
    bytes32 requestKey = 0x0e0cfee3dfef19a98e136e4bcd3ed52884a34e235ccda2c4af412d30b4957ce4;

    function run() public {
        vm.broadcast();
        positionManager.cancelMarketRequest(marketId, requestKey);
    }
}
