// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {IPriceFeed} from "../src/oracle/interfaces/IPriceFeed.sol";
import {WETH} from "../src/tokens/WETH.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {IHelperConfig} from "./IHelperConfig.s.sol";

contract HelperConfig is IHelperConfig, Script {
    NetworkConfig private activeNetworkConfig;

    uint256 public constant DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 97) {
            activeNetworkConfig = getBnbSepoliaConfig();
        } else if (block.chainid == 56) {
            activeNetworkConfig = getBnbConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getBnbSepoliaConfig() public returns (NetworkConfig memory bnbSepoliaConfig) {
        MockUSDC mockUsdc = MockUSDC(0x448A7D1dA6C7a9027caAC6f05309fa42361487E0);
        WETH weth = WETH(0x4200000000000000000000000000000000000006);

        bnbSepoliaConfig.contracts.weth = address(weth);
        bnbSepoliaConfig.contracts.usdc = address(mockUsdc);

        bnbSepoliaConfig.contracts.pyth = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
        bnbSepoliaConfig.mockFeed = false;

        bnbSepoliaConfig.contracts.ethPythId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
        bnbSepoliaConfig.contracts.usdcPythId = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

        activeNetworkConfig = bnbSepoliaConfig;
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function getBnbConfig() public returns (NetworkConfig memory bnbConfig) {
        bnbConfig.contracts.weth = 0x4200000000000000000000000000000000000006;
        bnbConfig.contracts.usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

        bnbConfig.contracts.pyth = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
        bnbConfig.mockFeed = false;

        bnbConfig.contracts.ethPythId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
        bnbConfig.contracts.usdcPythId = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

        activeNetworkConfig = bnbConfig;
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilConfig) {
        MockUSDC mockUsdc = new MockUSDC();
        WETH weth = new WETH();

        anvilConfig.contracts.weth = address(weth);
        anvilConfig.contracts.usdc = address(mockUsdc);

        anvilConfig.contracts.pyth = address(0);
        anvilConfig.mockFeed = true;
        anvilConfig.contracts.ethPythId = bytes32(0);
        anvilConfig.contracts.usdcPythId = bytes32(0);

        activeNetworkConfig = anvilConfig;
    }
}
