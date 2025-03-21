// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Vault} from "../markets/Vault.sol";
import {RewardTracker} from "../rewards/RewardTracker.sol";

/// @dev - External library to deploy contracts
library DeployRewardTracker {
    function run(address _vault, address _weth, address _usdc, string memory _name, string memory _symbol)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(_name, _symbol));
        return address(new RewardTracker{salt: salt}(_vault, _weth, _usdc, _name, _symbol));
    }
}
