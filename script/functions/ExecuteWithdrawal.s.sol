// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId, MarketIdLibrary} from "src/types/MarketId.sol";

contract ExecuteWithdrawal is Script {
    PositionManager positionManager = PositionManager(payable(0xdF1f52F5020DEaF52C52B00367c63928771E7D71));
    MarketId marketId = MarketId.wrap(0x69b9cda3342215535520e6b157ca90560845ae7d1e75fa59beebef34a49118ab);
    // Replace with key of request
    bytes32 requestKey = 0xc35dc58674a10fef5674830c580d183f733ee07cb7de351be133cb8f90d2da82;

    function run() public {
        vm.broadcast();
        positionManager.executeWithdrawal(marketId, requestKey);
    }
}
