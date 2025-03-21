// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

contract MultiDelegatecall {
    error DelegatecallFailed(uint256 index);

    struct Call {
        address target;
        bytes data;
    }

    function multiDelegatecall(Call[] memory calls) external payable returns (bytes[] memory results) {
        results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.delegatecall(calls[i].data);
            if (!success) {
                revert DelegatecallFailed(i);
            }
            results[i] = result;
        }
    }
}
