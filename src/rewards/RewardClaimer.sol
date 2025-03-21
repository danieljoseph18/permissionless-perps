// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IVault} from "../markets/interfaces/IVault.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";

contract RewardClaimer {
    error CallFailed(uint256 index);

    error RewardClaimer_InvaliPoolOwner();

    function claimAllRewards(address[] calldata _rewardTrackers) external {
        for (uint256 i = 0; i < _rewardTrackers.length;) {
            IRewardTracker(_rewardTrackers[i]).claimForAccount(msg.sender, msg.sender);

            unchecked {
                ++i;
            }
        }
    }
}
