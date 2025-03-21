// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {Execution} from "../positions/Execution.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {MarketId} from "../types/MarketId.sol";
/// @dev Needs PositionManager Role
// All keeper interactions should come through this contract
// Contract picks up and executes all requests, as well as holds intermediary funds.

contract PositionManager is IPositionManager, OwnableRoles, ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;
    using SafeTransferLib for IVault;

    IWETH immutable WETH;
    IERC20 immutable USDC;

    IMarketFactory public marketFactory;
    IReferralStorage public referralStorage;
    IPriceFeed public priceFeed;
    IMarket public market;
    ITradeStorage public tradeStorage;

    // Gas Limit for a Transfer
    uint256 public transferGasLimit;
    // Upper Bounds to account for fluctuations
    uint256 public averageDepositCost;
    uint256 public averageWithdrawalCost;
    uint256 public averagePositionCost;

    constructor(
        address _marketFactory,
        address _market,
        address _tradeStorage,
        address _referralStorage,
        address _priceFeed,
        address _tradeEngine,
        address _weth,
        address _usdc
    ) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        market = IMarket(_market);
        tradeStorage = ITradeStorage(_tradeStorage);
        referralStorage = IReferralStorage(_referralStorage);
        priceFeed = IPriceFeed(_priceFeed);
        WETH = IWETH(_weth);
        USDC = IERC20(_usdc);
        _grantRoles(_tradeEngine, _ROLE_6);
    }

    modifier isValidMarket(MarketId _id) {
        if (!marketFactory.isMarket(_id)) revert PositionManager_InvalidMarket();
        _;
    }

    receive() external payable {}

    function updateGasEstimates(uint256 _transfer, uint256 _deposit, uint256 _withdrawal, uint256 _position)
        external
        onlyOwner
    {
        transferGasLimit = _transfer;
        averageDepositCost = _deposit;
        averageWithdrawalCost = _withdrawal;
        averagePositionCost = _position;
        emit GasLimitsUpdated(_deposit, _withdrawal, _position);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    function updateMarketFactory(IMarketFactory _marketFactory) external onlyOwner {
        marketFactory = _marketFactory;
    }

    function updateReferralStorage(IReferralStorage _referralStorage) external onlyOwner {
        referralStorage = _referralStorage;
    }

    function executeDeposit(MarketId _id, bytes32 _key) external payable isValidMarket(_id) nonReentrant {
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();

        IVault.ExecuteDeposit memory params = MarketUtils.constructDepositParams(_id, priceFeed, market, _key);

        if (params.deposit.isLongToken) WETH.approve(address(params.vault), params.deposit.amountIn);
        else USDC.approve(address(params.vault), params.deposit.amountIn);

        uint256 mintAmount = market.executeDeposit(_id, params);

        IRewardTracker rewardTracker = params.vault.rewardTracker();

        params.vault.approve(address(rewardTracker), mintAmount);

        rewardTracker.stakeForAccount(address(this), params.deposit.owner, mintAmount, params.deposit.stakeDuration);

        uint256 feeForExecutor = ((initialGas - gasleft()) * tx.gasprice);
        uint256 availableBalance = address(this).balance;

        if (feeForExecutor > availableBalance) {
            feeForExecutor = availableBalance;
        }

        uint256 feeToRefund =
            feeForExecutor < params.deposit.executionFee ? params.deposit.executionFee - feeForExecutor : 0;

        SafeTransferLib.safeTransferETH(msg.sender, feeForExecutor);
        if (feeToRefund > 0) {
            SafeTransferLib.sendEthNoRevert(WETH, params.deposit.owner, feeToRefund, transferGasLimit, owner());
        }
    }

    function executeWithdrawal(MarketId _id, bytes32 _key) external payable isValidMarket(_id) nonReentrant {
        uint256 initialGas = gasleft();

        if (_key == bytes32(0)) revert PositionManager_InvalidKey();

        IVault.ExecuteWithdrawal memory params = MarketUtils.constructWithdrawalParams(_id, priceFeed, market, _key);

        IERC20(params.vault).approve(address(params.vault), params.withdrawal.amountIn);

        market.executeWithdrawal(_id, params);

        uint256 feeForExecutor = (initialGas - gasleft()) * tx.gasprice;

        uint256 availableBalance = address(this).balance;

        if (feeForExecutor > availableBalance) {
            feeForExecutor = availableBalance;
        }

        uint256 feeToRefund =
            feeForExecutor < params.withdrawal.executionFee ? params.withdrawal.executionFee - feeForExecutor : 0;

        SafeTransferLib.safeTransferETH(msg.sender, feeForExecutor);

        if (feeToRefund > 0) {
            SafeTransferLib.sendEthNoRevert(WETH, params.withdrawal.owner, feeToRefund, transferGasLimit, owner());
        }
    }

    function cancelMarketRequest(MarketId _id, bytes32 _requestKey) external isValidMarket(_id) nonReentrant {
        (address tokenOut, uint256 amountOut, bool shouldUnwrap) = market.cancelRequest(_id, _requestKey, msg.sender);

        if (shouldUnwrap) {
            WETH.withdraw(amountOut);
            SafeTransferLib.sendEthNoRevert(WETH, msg.sender, amountOut, transferGasLimit, owner());
        } else {
            IERC20(tokenOut).sendTokensNoRevert(msg.sender, amountOut, owner());
        }
        emit MarketRequestCancelled(_requestKey, msg.sender, tokenOut, amountOut);
    }

    /// @dev For market orders, can just pass in bytes32(0) as the request key, as it's only required for limits
    /// @dev If limit, caller needs to call Router.requestExecutionPricing before, and provide the requestKey as input
    function executePosition(MarketId _id, bytes32 _orderKey, bytes32 _requestKey, address _feeReceiver)
        external
        payable
        isValidMarket(_id)
        nonReentrant
    {
        uint256 initialGas = gasleft();

        (Execution.FeeState memory feeState, Position.Request memory request) =
            tradeStorage.executePositionRequest(_id, _orderKey, _requestKey, _feeReceiver);

        emit ExecutePosition(MarketId.unwrap(_id), _orderKey, feeState.positionFee, feeState.affiliateRebate);

        if (feeState.affiliateRebate > 0) {
            emit UserReferred(
                request.user,
                feeState.referrer,
                request.input.sizeDelta,
                feeState.affiliateRebate,
                request.input.isLong,
                referralStorage.traderReferralCodes(request.user)
            );
        }

        uint256 executionCost = (initialGas - gasleft()) * tx.gasprice;

        uint256 availableBalance = address(this).balance;

        if (executionCost > availableBalance) {
            executionCost = availableBalance;
        }

        if (executionCost > request.input.executionFee) {
            SafeTransferLib.safeTransferETH(msg.sender, executionCost);
        } else {
            uint256 feeToRefund = request.input.executionFee - executionCost;

            SafeTransferLib.safeTransferETH(msg.sender, executionCost);

            if (feeToRefund > 0) {
                SafeTransferLib.sendEthNoRevert(WETH, request.user, feeToRefund, transferGasLimit, owner());
            }
        }
    }

    // Only person who requested the pricing for an order should be able to initiate the liquidation,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before
    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey)
        external
        payable
        isValidMarket(_id)
        nonReentrant
    {
        tradeStorage.liquidatePosition(_id, _positionKey, _requestKey, msg.sender);
    }

    function cancelOrderRequest(MarketId _id, bytes32 _key, bool _isLimit)
        external
        payable
        isValidMarket(_id)
        nonReentrant
    {
        Position.Request memory request = tradeStorage.getOrder(_id, _key);

        if (request.user == address(0)) revert PositionManager_RequestDoesNotExist();

        if (block.timestamp < request.requestTimestamp + tradeStorage.minCancellationTime()) {
            revert PositionManager_InsufficientDelay();
        }

        if (!request.input.isLimit) {
            if (msg.sender != request.user) {
                if (!priceFeed.isRequestValid(request.requestKey)) revert PositionManager_CancellationFailed();
            }
        } else {
            // Only the user can cancel a limit order
            if (msg.sender != request.user) revert PositionManager_CancellationFailed();
        }

        tradeStorage.cancelOrderRequest(_id, _key, _isLimit);

        // Cancel associated conditional orders
        if (_isLimit) {
            // If a stop loss or tp is cancelled, we should remove the key from the associated position
            bytes32 positionKey = Position.generateKey(request);
            Position.Data memory position = tradeStorage.getPosition(_id, positionKey);
            if (position.stopLossKey != bytes32(0)) {
                tradeStorage.clearConditionalOrder(_id, positionKey, true);
            }
            if (position.takeProfitKey != bytes32(0)) {
                tradeStorage.clearConditionalOrder(_id, positionKey, false);
            }
        } else {
            // If associated SL / TP, clear them
            if (request.stopLossKey != bytes32(0)) {
                tradeStorage.cancelOrderRequest(_id, request.stopLossKey, true);
            }
            if (request.takeProfitKey != bytes32(0)) {
                tradeStorage.cancelOrderRequest(_id, request.takeProfitKey, true);
            }
        }

        // Refund and collateral tokens transferred in
        if (request.input.isIncrease) {
            IERC20(request.input.collateralToken).sendTokensNoRevert(
                request.user, request.input.collateralDelta, owner()
            );
        }

        (uint256 refundAmount, uint256 amountForExecutor) = Gas.getRefundForCancellation(request.input.executionFee);

        if (msg.sender == request.user) {
            SafeTransferLib.sendEthNoRevert(
                WETH, msg.sender, refundAmount + amountForExecutor, transferGasLimit, owner()
            );
        } else {
            SafeTransferLib.sendEthNoRevert(WETH, request.user, refundAmount, transferGasLimit, owner());
            SafeTransferLib.sendEthNoRevert(WETH, msg.sender, amountForExecutor, transferGasLimit, owner());
        }
    }

    // Only person who requested the pricing for an order should be able to initiate the adl,
    // up until a certain time buffer. After that time buffer, any user should be able to.
    /// @dev - Caller needs to call Router.requestExecutionPricing before and provide a valid requestKey
    function executeAdl(MarketId _id, bytes32 _requestKey, bytes32 _positionKey)
        external
        payable
        isValidMarket(_id)
        nonReentrant
    {
        tradeStorage.executeAdl(_id, _positionKey, _requestKey, msg.sender);
    }

    /// @dev - Should only be callable from the TradeEngine associated with a valid market
    function transferTokensForIncrease(
        IVault vault,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate,
        uint256 _feeForExecutor,
        address _executor
    ) external onlyRoles(_ROLE_6) {
        uint256 transferAmount = _collateralDelta;

        if (_feeForExecutor > 0) {
            transferAmount -= _feeForExecutor;
            IERC20(_collateralToken).sendTokensNoRevert(_executor, _feeForExecutor, owner());
        }

        if (_affiliateRebate > 0) {
            transferAmount -= _affiliateRebate;
            IERC20(_collateralToken).safeTransfer(address(referralStorage), _affiliateRebate);
        }

        IERC20(_collateralToken).safeTransfer(address(vault), transferAmount);
    }
}
