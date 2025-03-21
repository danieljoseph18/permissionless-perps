// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";

type MarketId is bytes32;

library MarketIdLibrary {
    function toId(IMarketFactory.Input memory _input) internal pure returns (MarketId marketId) {
        return MarketId.wrap(keccak256(abi.encode(_input)));
    }
}
