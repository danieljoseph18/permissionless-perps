// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Oracle} from "../src/oracle/Oracle.sol";

interface IHelperConfig {
    struct NetworkConfig {
        Contracts contracts;
        bool mockFeed;
    }

    struct Contracts {
        address weth;
        address usdc;
        address pyth;
        bytes32 ethPythId;
        bytes32 usdcPythId;
    }

    function getActiveNetworkConfig() external view returns (NetworkConfig memory);
}
