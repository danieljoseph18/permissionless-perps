// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Vault} from "../markets/Vault.sol";

/// @dev - External library to deploy contracts
library DeployVault {
    function run(IMarketFactory.Request calldata _params, address _weth, address _usdc, bytes32 _marketId)
        external
        returns (address)
    {
        bytes32 salt =
            keccak256(abi.encode(_params.requester, _params.input.marketTokenName, _params.input.marketTokenSymbol));
        return address(
            new Vault{salt: salt}(
                _params.requester,
                _weth,
                _usdc,
                _params.input.marketTokenName,
                _params.input.marketTokenSymbol,
                _marketId
            )
        );
    }
}
