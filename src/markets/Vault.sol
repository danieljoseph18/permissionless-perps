// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "../tokens/ERC20.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IFeeDistributor} from "../rewards/interfaces/IFeeDistributor.sol";
import {Units} from "../libraries/Units.sol";

contract Vault is ERC20, IVault, OwnableRoles, ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;
    using SafeTransferLib for Vault;
    using Units for uint256;

    address private immutable WETH;
    address private immutable USDC;

    uint64 private constant FEE_TO_LPS = 0.7e18; // 70%

    IMarket market;
    IRewardTracker public rewardTracker;
    IFeeDistributor public feeDistributor;

    bytes32 public marketId;

    address public poolOwner;
    address public feeReceiver;

    uint256 public transferGasLimit;

    uint256 public longAccumulatedFees;
    uint256 public shortAccumulatedFees;
    uint256 public longTokenBalance;
    uint256 public shortTokenBalance;
    uint256 public longTokensReserved;
    uint256 public shortTokensReserved;

    uint256 public longCollateral;
    uint256 public shortCollateral;

    bool private isInitialized;

    mapping(address user => mapping(bool _isLong => uint256 collateralAmount)) public collateralAmounts;

    mapping(bool _isLong => uint256 amount) public badDebt;

    mapping(bytes32 key => uint256 mintAmount) public depositMintAmounts;
    mapping(bytes32 key => uint256 transferAmount) public withdrawalAmountOuts;

    mapping(address => bool) public isOptimizer;

    modifier onlyAdmin() {
        if (msg.sender != owner() && rolesOf(msg.sender) != _ROLE_2) revert Vault_AccessDenied();
        _;
    }

    constructor(
        address _poolOwner,
        address _weth,
        address _usdc,
        string memory _name,
        string memory _symbol,
        bytes32 _marketId
    ) ERC20(_name, _symbol, 18) {
        _initializeOwner(msg.sender);
        _grantRoles(_poolOwner, _ROLE_2); // Pool Owner
        poolOwner = _poolOwner;
        WETH = _weth;
        USDC = _usdc;
        marketId = _marketId;
    }

    /// @dev Required to receive ETH when unwrapping WETH for transfers out.
    receive() external payable {}

    function initialize(
        address _market,
        address _feeDistributor,
        address _rewardTracker,
        address _tradeEngine,
        address _feeReceiver,
        uint256 _transferGasLimit
    ) external onlyOwner {
        if (isInitialized) revert Vault_AlreadyInitialized();
        market = IMarket(_market);
        feeDistributor = IFeeDistributor(_feeDistributor);
        rewardTracker = IRewardTracker(_rewardTracker);
        feeReceiver = _feeReceiver;
        transferGasLimit = _transferGasLimit;
        _grantRoles(_market, _ROLE_7);
        _grantRoles(_tradeEngine, _ROLE_6);
        isInitialized = true;
    }

    function replaceTradeEngine(address _previousTradeEngine, address _newTradeEngine) external onlyOwner {
        revokeRoles(_previousTradeEngine, _ROLE_6);
        _grantRoles(_newTradeEngine, _ROLE_6);
    }

    function setIsOptimizer(address _optimizer, bool _isValid) external onlyOwner {
        isOptimizer[_optimizer] = _isValid;
    }

    /**
     * =========================================== Storage Functions ===========================================
     */
    function updateLiquidityReservation(uint256 _amount, bool _isLong, bool _isIncrease) external onlyRoles(_ROLE_6) {
        if (_isIncrease) {
            _isLong ? longTokensReserved += _amount : shortTokensReserved += _amount;
        } else {
            if (_isLong) {
                if (_amount > longTokensReserved) longTokensReserved = 0;
                else longTokensReserved -= _amount;
            } else {
                if (_amount > shortTokensReserved) shortTokensReserved = 0;
                else shortTokensReserved -= _amount;
            }
        }
    }

    function updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) external onlyRoles(_ROLE_6) {
        _updatePoolBalance(_amount, _isLong, _isIncrease);
    }

    /// @dev Collateral can fluctuate in value, while position's collateral is denominated in a fixed USD value.
    /// This can cause discrepancies in the collateral supplied, vs the collateral allocated to a user's position.
    /// This function is required to keep the accounting consistent, and settle any excess / deficits.
    function updateCollateralAmount(uint256 _amount, address _user, bool _isLong, bool _isIncrease, bool _isFullClose)
        external
        onlyRoles(_ROLE_6)
    {
        uint256 currentCollateral = collateralAmounts[_user][_isLong];

        if (_isIncrease) {
            collateralAmounts[_user][_isLong] += _amount;
            if (_isLong) {
                longCollateral += _amount;
            } else {
                shortCollateral += _amount;
            }
        } else {
            if (_amount >= currentCollateral) {
                uint256 excess = _amount - currentCollateral;
                collateralAmounts[_user][_isLong] = 0;

                if (_isLong) {
                    uint256 availableTokens = longTokenBalance - longTokensReserved;
                    if (excess > availableTokens) {
                        longTokenBalance = longTokensReserved;
                        uint256 badDebtAccrued = excess - availableTokens;
                        badDebt[_isLong] += badDebtAccrued;
                        emit BadDebtCreated(badDebtAccrued, _isLong);
                    } else {
                        longTokenBalance -= excess;
                    }
                    longCollateral = (longCollateral > currentCollateral) ? longCollateral - currentCollateral : 0;
                } else {
                    uint256 availableTokens = shortTokenBalance - shortTokensReserved;
                    if (excess > availableTokens) {
                        shortTokenBalance = shortTokensReserved;
                        uint256 badDebtAccrued = excess - availableTokens;
                        badDebt[_isLong] += badDebtAccrued;
                        emit BadDebtCreated(badDebtAccrued, _isLong);
                    } else {
                        shortTokenBalance -= excess;
                    }
                    shortCollateral = (shortCollateral > currentCollateral) ? shortCollateral - currentCollateral : 0;
                }
            } else {
                collateralAmounts[_user][_isLong] -= _amount;
                if (_isLong) {
                    longCollateral = (longCollateral > _amount) ? longCollateral - _amount : 0;
                } else {
                    shortCollateral = (shortCollateral > _amount) ? shortCollateral - _amount : 0;
                }
            }
            // If the position is closed, we add any remainance to the respective pool balance
            if (_isFullClose) {
                uint256 remaining = collateralAmounts[_user][_isLong];
                if (remaining > 0) {
                    collateralAmounts[_user][_isLong] = 0;
                    if (_isLong) {
                        longTokenBalance += remaining;
                        longCollateral = (longCollateral > remaining) ? longCollateral - remaining : 0;
                    } else {
                        shortTokenBalance += remaining;
                        shortCollateral = (shortCollateral > remaining) ? shortCollateral - remaining : 0;
                    }
                }
            }
        }
    }

    function accumulateFees(uint256 _amount, bool _isLong) external onlyRoles(_ROLE_6) {
        _accumulateFees(_amount, _isLong);
    }

    function batchWithdrawFees() external onlyAdmin nonReentrant {
        uint256 longFees = longAccumulatedFees;
        uint256 shortFees = shortAccumulatedFees;

        // Reset accumulated fees
        longAccumulatedFees = 0;
        shortAccumulatedFees = 0;

        // Calculate LP and ownership fees
        uint256 longLpFees = longFees.percentage(FEE_TO_LPS);
        uint256 shortLpFees = shortFees.percentage(FEE_TO_LPS);

        uint256 longOwnershipFees = longFees - longLpFees;
        uint256 shortOwnershipFees = shortFees - shortLpFees;

        // Settle bad debt and calculate remaining fees
        uint256 remainingFeesLong = longOwnershipFees;
        uint256 remainingFeesShort = shortOwnershipFees;

        if (badDebt[true] > 0) {
            remainingFeesLong = _settleBadDebt(longOwnershipFees, true);
        }

        if (badDebt[false] > 0) {
            remainingFeesShort = _settleBadDebt(shortOwnershipFees, false);
        }

        // Distribute LP fees
        address distributor = address(feeDistributor);
        IERC20(WETH).approve(distributor, longLpFees);
        IERC20(USDC).approve(distributor, shortLpFees);
        IFeeDistributor(distributor).accumulateFees(longLpFees, shortLpFees);

        address holdingAddr = owner();

        if (remainingFeesLong > 0) {
            uint256 longConfiguratorFee = remainingFeesLong / 2;

            IERC20(WETH).sendTokensNoRevert(poolOwner, longConfiguratorFee, holdingAddr);

            IERC20(WETH).sendTokensNoRevert(feeReceiver, remainingFeesLong - longConfiguratorFee, holdingAddr);
        }

        if (remainingFeesShort > 0) {
            uint256 shortConfiguratorFee = remainingFeesShort / 2;

            IERC20(USDC).sendTokensNoRevert(poolOwner, shortConfiguratorFee, holdingAddr);

            IERC20(USDC).sendTokensNoRevert(feeReceiver, remainingFeesShort - shortConfiguratorFee, holdingAddr);
        }

        emit FeesWithdrawn(longFees, shortFees);
    }

    function executeDeposit(ExecuteDeposit calldata _params, address _tokenIn, address _positionManager)
        external
        onlyRoles(_ROLE_7)
        returns (uint256)
    {
        uint256 initialBalance =
            _params.deposit.isLongToken ? IERC20(WETH).balanceOf(address(this)) : IERC20(USDC).balanceOf(address(this));

        IERC20(_tokenIn).safeTransferFrom(_positionManager, address(this), _params.deposit.amountIn);

        (uint256 afterFeeAmount, uint256 fee, uint256 mintAmount) = MarketUtils.calculateDepositAmounts(_params);

        _accumulateFees(fee, _params.deposit.isLongToken);
        _updatePoolBalance(afterFeeAmount, _params.deposit.isLongToken, true);

        emit DepositExecuted(
            _params.key, _params.deposit.owner, _params.deposit.amountIn, mintAmount, _params.deposit.isLongToken
        );

        _mint(address(_positionManager), mintAmount);

        _validateDeposit(initialBalance, _params.deposit.amountIn, _params.deposit.isLongToken);

        // Store the mint amount
        depositMintAmounts[_params.key] = mintAmount;

        return mintAmount;
    }

    function executeWithdrawal(ExecuteWithdrawal calldata _params, address _tokenOut, address _positionManager)
        external
        onlyRoles(_ROLE_7)
    {
        uint256 initialBalance = _params.withdrawal.isLongToken
            ? IERC20(WETH).balanceOf(address(this))
            : IERC20(USDC).balanceOf(address(this));

        this.safeTransferFrom(_positionManager, address(this), _params.withdrawal.amountIn);

        (uint256 transferAmountOut, uint256 amountOut) = MarketUtils.calculateWithdrawalAmounts(_params);

        _burn(address(this), _params.withdrawal.amountIn);

        _accumulateFees(amountOut - transferAmountOut, _params.withdrawal.isLongToken);

        uint256 availableTokens = _params.withdrawal.isLongToken
            ? longTokenBalance - longTokensReserved
            : shortTokenBalance - shortTokensReserved;

        if (transferAmountOut > availableTokens) revert Vault_InsufficientAvailableTokens();

        _updatePoolBalance(amountOut, _params.withdrawal.isLongToken, false);

        emit WithdrawalExecuted(
            _params.key,
            _params.withdrawal.owner,
            _params.withdrawal.amountIn,
            transferAmountOut,
            _params.withdrawal.isLongToken
        );

        _transferOutTokens(
            _tokenOut,
            _params.withdrawal.owner,
            transferAmountOut,
            _params.withdrawal.isLongToken,
            _params.withdrawal.reverseWrap
        );

        _validateWithdrawal(initialBalance, transferAmountOut, _params.withdrawal.isLongToken);

        // Store the transfer amount
        withdrawalAmountOuts[_params.key] = transferAmountOut;
    }

    /**
     * =========================================== Token Transfers ===========================================
     */
    function transferOutTokens(address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        external
        onlyRoles(_ROLE_6)
    {
        _transferOutTokens(_isLongToken ? WETH : USDC, _to, _amount, _isLongToken, _shouldUnwrap);
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _transferOutTokens(address _tokenOut, address _to, uint256 _amount, bool _isLongToken, bool _shouldUnwrap)
        private
    {
        if (_isLongToken) {
            if (_shouldUnwrap) {
                IWETH(_tokenOut).withdraw(_amount);
                IWETH(_tokenOut).sendEthNoRevert(_to, _amount, transferGasLimit, owner());
            } else {
                IERC20(_tokenOut).sendTokensNoRevert(_to, _amount, owner());
            }
        } else {
            IERC20(_tokenOut).sendTokensNoRevert(_to, _amount, owner());
        }
    }

    function _updatePoolBalance(uint256 _amount, bool _isLong, bool _isIncrease) private {
        if (_isIncrease) {
            _isLong ? longTokenBalance += _amount : shortTokenBalance += _amount;
        } else {
            if (_isLong) {
                uint256 availableTokens = longTokenBalance - longTokensReserved;
                if (_amount > availableTokens) revert Vault_InsufficientAvailableTokens();
                longTokenBalance -= _amount;
            } else {
                uint256 availableTokens = shortTokenBalance - shortTokensReserved;
                if (_amount > availableTokens) revert Vault_InsufficientAvailableTokens();
                shortTokenBalance -= _amount;
            }
        }
    }

    function _accumulateFees(uint256 _amount, bool _isLong) private {
        _isLong ? longAccumulatedFees += _amount : shortAccumulatedFees += _amount;
        emit FeesAccumulated(_amount, _isLong);
    }

    function _settleBadDebt(uint256 _availableSettlement, bool _isLong)
        private
        returns (uint256 afterSettlementAmount)
    {
        uint256 debt = badDebt[_isLong];

        if (_availableSettlement >= debt) {
            badDebt[_isLong] = 0;
            _isLong ? longTokenBalance += debt : shortTokenBalance += debt;
            afterSettlementAmount = _availableSettlement - debt;
        } else {
            badDebt[_isLong] -= _availableSettlement;
            _isLong ? longTokenBalance += _availableSettlement : shortTokenBalance += _availableSettlement;
            afterSettlementAmount = 0;
        }
    }

    function _validateDeposit(uint256 _initialBalance, uint256 _amountIn, bool _isLong) private view {
        if (_isLong) {
            uint256 wethBalance = IERC20(WETH).balanceOf(address(this));

            if (longTokenBalance > wethBalance) revert Vault_InvalidDeposit();

            if (wethBalance != _initialBalance + _amountIn) {
                revert Vault_InvalidDeposit();
            }
        } else {
            uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));

            if (shortTokenBalance > usdcBalance) revert Vault_InvalidDeposit();

            if (usdcBalance != _initialBalance + _amountIn) {
                revert Vault_InvalidDeposit();
            }
        }
    }

    function _validateWithdrawal(uint256 _initialBalance, uint256 _amountOut, bool _isLong) private view {
        if (_isLong) {
            uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
            if (longTokenBalance > wethBalance) revert Vault_InvalidWithdrawal();
            if (wethBalance != _initialBalance - _amountOut) {
                revert Vault_InvalidWithdrawal();
            }
        } else {
            uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
            if (shortTokenBalance > usdcBalance) revert Vault_InvalidWithdrawal();
            if (usdcBalance != _initialBalance - _amountOut) {
                revert Vault_InvalidWithdrawal();
            }
        }
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function totalAvailableLiquidity(bool _isLong) external view returns (uint256 total) {
        total = _isLong ? longTokenBalance - longTokensReserved : shortTokenBalance - shortTokensReserved;
    }
}
