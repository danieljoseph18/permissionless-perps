// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {PriceFeed} from "src/oracle/PriceFeed.sol";
import {IPositionManager} from "src/router/interfaces/IPositionManager.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestSetPricesExecuteDeposit is Test {
    PriceFeed priceFeed = PriceFeed(payable(0xa04970e19237Cf779DdA2d890278DAc7695726eB));
    IPositionManager positionManager = IPositionManager(0x330D2b0CaDDB217459eC8E018F6c27bf5F9757f0);

    address caller = 0xF0bE92981E8b65e9a1988077D0b5D784ECbcedF5;

    // Set to block to emulate for simulation
    uint256 constant FORK_BLOCK_NUMBER = 22625032;
    // Set to a reasonable gas price for the respective chain
    uint256 constant GAS_PRICE = 7045021315; // 7.045021315 Gwei in wei

    uint256 forkId;

    // Encoded Price Data
    bytes priceData =
        "0x4254433a31000000000000000000000b00000000674d481e002259347c3c6b8a4554483a31000000000000000000000c00000000674d481e000d20526c0855fa555344433a310000000000000000001000000000674d481e0023855ace9e43dc";
    // Encoded error, if any (0x if no error)
    bytes err = "0x";
    // MarketId
    bytes32 id = 0xdd915408a63a72e350e9a729b03ad788fece16b23cc5930311da5ffd5131851e;
    // OrderKey
    bytes32 orderKey = 0xa9b6a941af869e99b6c5a45bb046d5fa973f2686f143acda38f87757d3726333;
    // The RequestId of the price request for the deposit / withdrawal
    bytes32 requestId = 0x08695baefb266dc703e8fe3291f6057f00052e5459c4e804251b53c3ddac7bd4;
    // Is it a deposit or a withdrawal
    bool isDeposit = true;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_set_prices_and_execute_deposit_fork() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        vm.prank(caller);
        priceFeed.setPricesAndExecuteDepositWithdrawal(
            positionManager, priceData, err, MarketId.wrap(id), orderKey, requestId, isDeposit
        );
    }
}
