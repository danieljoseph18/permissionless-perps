// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {Ownable} from "src/auth/Ownable.sol";

/// @dev Testnet faucet
contract Faucet is Ownable {
    IERC20 public usdcToken;
    uint256 public ethAmount;
    uint256 public usdcAmount;

    mapping(address => bool) public hasClaimedEth;
    mapping(address => bool) public hasClaimedUSDC;

    event EthClaimed(address indexed claimer, uint256 amount);
    event USDCClaimed(address indexed claimer, uint256 amount);

    constructor(address _usdcToken, uint256 _ethAmount, uint256 _usdcAmount) {
        _initializeOwner(msg.sender);
        usdcToken = IERC20(_usdcToken);
        ethAmount = _ethAmount;
        usdcAmount = _usdcAmount;
    }

    function claimEth() external {
        require(!hasClaimedEth[msg.sender], "ETH already claimed");
        require(address(this).balance >= ethAmount, "Insufficient ETH in contract");

        hasClaimedEth[msg.sender] = true;
        payable(msg.sender).transfer(ethAmount);

        emit EthClaimed(msg.sender, ethAmount);
    }

    function claimUSDC() external {
        require(!hasClaimedUSDC[msg.sender], "USDC already claimed");
        require(usdcToken.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC in contract");

        hasClaimedUSDC[msg.sender] = true;
        require(usdcToken.transfer(msg.sender, usdcAmount), "USDC transfer failed");

        emit USDCClaimed(msg.sender, usdcAmount);
    }

    function depositEth() external payable onlyOwner {}

    function withdrawAllEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        payable(owner()).transfer(balance);
    }

    function withdrawAllUSDC() external onlyOwner {
        uint256 balance = usdcToken.balanceOf(address(this));
        require(balance > 0, "No USDC to withdraw");
        require(usdcToken.transfer(owner(), balance), "USDC transfer failed");
    }

    function withdrawEth(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient ETH in contract");
        payable(owner()).transfer(amount);
    }

    function withdrawUSDC(uint256 amount) external onlyOwner {
        require(usdcToken.balanceOf(address(this)) >= amount, "Insufficient USDC in contract");
        require(usdcToken.transfer(owner(), amount), "USDC transfer failed");
    }

    function setEthAmount(uint256 _ethAmount) external onlyOwner {
        ethAmount = _ethAmount;
    }

    function setUsdcAmount(uint256 _usdcAmount) external onlyOwner {
        usdcAmount = _usdcAmount;
    }
}
