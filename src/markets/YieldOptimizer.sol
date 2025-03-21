// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "../tokens/ERC20.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeERC20} from "../tokens/SafeERC20.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IVault} from "./interfaces/IVault.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {IRouter} from "../router/interfaces/IRouter.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {MarketId} from "../types/MarketId.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {Casting} from "../libraries/Casting.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {Gas} from "../libraries/Gas.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {Pool} from "./Pool.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

/**
 * @title YieldOptimizer
 */
contract YieldOptimizer is ERC20, OwnableRoles, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathUtils for uint256;
    using MathUtils for int256;
    using Casting for uint256;
    using Casting for int256;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    event YieldCollected(uint256 wethAmount, uint256 usdcAmount);
    event YieldClaimed(address indexed user, uint256 wethAmount, uint256 usdcAmount);
    event DepositExecuted(bytes32 requestId, address owner, uint256 failedAmount, uint256 successfulAmount);
    event WithdrawalExecuted(bytes32 requestId, address owner, uint256 wethAmount, uint256 usdcAmount);
    event DepositFailed(bytes32 indexed requestKey, address strategy, uint256 amount);
    event DepositSucceeded(bytes32 indexed requestKey, address strategy, uint256 amount, uint256 lpTokens);
    event WithdrawalFailed(bytes32 indexed requestKey, address strategy, uint256 amount);
    event WithdrawalSucceeded(bytes32 indexed requestKey, address strategy, uint256 amount);
    event SharesMinted(address indexed user, uint256 shares, uint256 amount);
    event SharesBurned(address indexed user, uint256 shares, uint256 amount);
    event DepositRefunded(address indexed user, address token, uint256 amount);
    event DepositCreated(bytes32 indexed requestKey, address owner, uint256 amount, address token);
    event WithdrawalCreated(bytes32 indexed requestKey, address owner, uint256 shares, address token);

    error YieldOptimizer_InvalidAllocation();
    error YieldOptimizer_NoShares();
    error YieldOptimizer_InvalidDepositToken();
    error YieldOptimizer_InsufficientShares();
    error YieldOptimizer_InvalidAmountIn();
    error YieldOptimizer_InsufficientExecutionFee();
    error YieldOptimizer_RequestNotFound();
    error YieldOptimizer_AlreadyInitialized();
    error YieldOptimizer_InvalidWithdrawalToken();
    error YieldOptimizer_LastPriceZero();
    error YieldOptimizer_WithdrawalCooldown();

    struct Strategy {
        IVault vault;
        IRewardTracker rewardTracker;
        MarketId marketId;
        uint8 allocation; // Percentage allocation (1-100)
    }

    struct OpenRequest {
        address owner;
        uint256 amount;
        address token;
        uint256 timestamp;
        bytes32[] requestKeys;
    }

    struct FailedRequest {
        address owner;
        bytes32 requestKey;
        MarketId marketId;
        address token;
        uint256 amount;
    }

    IMarket public market;
    Strategy[] private strategies;
    bool public initialized;

    uint16 public cooldownDuration;

    address public router;
    address public positionManager;
    address public priceFeed;
    address public weth;
    address public usdc;

    uint256 public accumulatedWethYield;
    uint256 public accumulatedUsdcYield;
    uint256 public executionFeePerDeposit;

    uint256 public minEthDeposit;
    uint256 public minUsdcDeposit;

    uint256 private accumulatedWethYieldPerShare;
    uint256 private accumulatedUsdcYieldPerShare;

    EnumerableSetLib.Bytes32Set private openRequestKeys;
    mapping(bytes32 key => OpenRequest) private withdrawalRequests;
    mapping(bytes32 key => OpenRequest) private depositRequests;
    mapping(address user => uint256 wethYieldDebt) private userWethYieldDebt;
    mapping(address user => uint256 usdcYieldDebt) private userUsdcYieldDebt;
    mapping(address token => bool) private isDepositToken;
    mapping(bytes32 requestKey => FailedRequest) private failedRequests;
    mapping(address user => EnumerableSetLib.Bytes32Set failedRequestKeys) private userFailedRequestKeys;
    // Safety Check
    mapping(address user => uint256 cooldownEndTime) private withdrawalCooldowns;

    constructor(string memory _name, string memory _symbol, address _weth, address _usdc, address _market)
        ERC20(_name, _symbol, 18)
    {
        _initializeOwner(msg.sender);

        // Add WETH, USDC and ETH as deposit tokens
        isDepositToken[_weth] = true;
        isDepositToken[_usdc] = true;
        isDepositToken[address(0)] = true;

        market = IMarket(_market);

        weth = _weth;
        usdc = _usdc;

        // Initialize supported deposit tokens
        minEthDeposit = 0.01 ether; // Init min deposit
        minUsdcDeposit = 20e6; // Init min deposit
    }

    receive() external payable {}

    function initialize(
        address _router,
        address _positionManager,
        address _priceFeed,
        uint256 _minEthDeposit,
        uint256 _minUsdcDeposit,
        uint256 _executionFeePerDeposit,
        IVault[] calldata _vaults,
        uint8[] calldata _allocations
    ) external onlyOwner {
        if (initialized) revert YieldOptimizer_AlreadyInitialized();
        if (_vaults.length != _allocations.length) revert YieldOptimizer_InvalidAllocation();

        router = _router;
        positionManager = _positionManager;
        priceFeed = _priceFeed;
        minEthDeposit = _minEthDeposit;
        minUsdcDeposit = _minUsdcDeposit;
        executionFeePerDeposit = _executionFeePerDeposit;

        // Set init cooldown to 2 minutes
        cooldownDuration = 2 minutes;

        uint8 totalAllocation;
        for (uint256 i = 0; i < _vaults.length;) {
            totalAllocation += _allocations[i];
            strategies.push(
                Strategy({
                    vault: _vaults[i],
                    rewardTracker: _vaults[i].rewardTracker(),
                    marketId: MarketId.wrap(_vaults[i].marketId()),
                    allocation: _allocations[i]
                })
            );
            unchecked {
                ++i;
            }
        }

        if (totalAllocation != 100) revert YieldOptimizer_InvalidAllocation();
        initialized = true;
    }

    function setCooldownDuration(uint16 _cooldownDuration) external onlyOwner {
        cooldownDuration = _cooldownDuration;
    }

    /**
     * @notice Recover function in the event of contract issues etc.
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            SafeTransferLib.sendEthNoRevert(IWETH(weth), owner(), _amount, 21000, owner());
        } else {
            SafeTransferLib.sendTokensNoRevert(IERC20(_token), owner(), _amount, owner());
        }
    }

    function refundFailedRequests() external {
        // Get the user's failed request keys
        EnumerableSetLib.Bytes32Set storage failedRequestKeys = userFailedRequestKeys[msg.sender];

        // Store the keys in memory first to avoid modifying while iterating
        bytes32[] memory keysToProcess = failedRequestKeys.values();
        uint256 len = keysToProcess.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 failedRequestKey = keysToProcess[i];
            FailedRequest memory failedRequest = failedRequests[failedRequestKey];

            // Try to cancel the request, continue if it fails
            try IPositionManager(positionManager).cancelMarketRequest(failedRequest.marketId, failedRequest.requestKey)
            {
                // Only refund if cancellation was successful
                if (failedRequest.token == weth) {
                    IWETH(weth).withdraw(failedRequest.amount);
                    SafeTransferLib.sendEthNoRevert(
                        IWETH(weth), failedRequest.owner, failedRequest.amount, 21000, owner()
                    );
                } else {
                    IERC20(failedRequest.token).safeTransfer(failedRequest.owner, failedRequest.amount);
                }

                // Clean up storage after successful refund
                delete failedRequests[failedRequestKey];
                failedRequestKeys.remove(failedRequestKey);
            } catch {
                // Remove failed request from storage and continue
                delete failedRequests[failedRequestKey];
                failedRequestKeys.remove(failedRequestKey);
                continue;
            }
        }
    }

    function collectYield() public nonReentrant {
        _collectYield();
    }

    function claimYield() external nonReentrant returns (uint256 wethAmount, uint256 usdcAmount) {
        uint256 userShares = balanceOf[msg.sender];
        if (userShares == 0) revert YieldOptimizer_NoShares();

        _collectYield();

        uint256 totalShares = totalSupply;

        uint256 newWethYieldPerShare = MathUtils.mulDiv(accumulatedWethYield, 1e18, totalShares);
        uint256 newUsdcYieldPerShare = MathUtils.mulDiv(accumulatedUsdcYield, 1e18, totalShares);

        wethAmount = MathUtils.mulDiv(newWethYieldPerShare, userShares, 1e18) - userWethYieldDebt[msg.sender];
        usdcAmount = MathUtils.mulDiv(newUsdcYieldPerShare, userShares, 1e18) - userUsdcYieldDebt[msg.sender];

        userWethYieldDebt[msg.sender] += wethAmount;
        userUsdcYieldDebt[msg.sender] += usdcAmount;

        if (wethAmount > 0) {
            accumulatedWethYield -= wethAmount;
            IERC20(weth).safeTransfer(msg.sender, wethAmount);
        }
        if (usdcAmount > 0) {
            accumulatedUsdcYield -= usdcAmount;
            IERC20(usdc).safeTransfer(msg.sender, usdcAmount);
        }

        emit YieldClaimed(msg.sender, wethAmount, usdcAmount);
    }

    function createDeposit(address _token, uint256 _amount) external payable nonReentrant {
        if (!isDepositToken[_token]) revert YieldOptimizer_InvalidDepositToken();

        // If token is ETH / WETH, min deposit is minEthDeposit
        if (_amount < minEthDeposit && (_token == address(0) || _token == weth)) {
            revert YieldOptimizer_InvalidAmountIn();
        }
        // If token is USDC, min deposit is minUsdcDeposit
        if (_amount < minUsdcDeposit && _token == usdc) revert YieldOptimizer_InvalidAmountIn();

        uint256 depositAmount = _amount;
        uint256 strategiesLength = strategies.length;
        uint256 totalExecutionFee = executionFeePerDeposit * strategiesLength;

        if (_token == address(0)) {
            if (msg.value < _amount + totalExecutionFee) revert YieldOptimizer_InvalidAmountIn();
            depositAmount = _amount;
            IWETH(weth).deposit{value: depositAmount}();
        } else {
            if (msg.value < totalExecutionFee) {
                revert YieldOptimizer_InsufficientExecutionFee();
            }
            IERC20(_token).safeTransferFrom(msg.sender, address(this), depositAmount);
        }

        // WETH has been deposited, so set token to spend to WETH
        address tokenToSpend = _token == address(0) ? weth : _token;

        IERC20(tokenToSpend).approve(address(router), depositAmount);

        bytes32 depositKey = _generateKey(msg.sender, depositAmount, _token, true);

        bytes32[] memory requestKeys = new bytes32[](strategiesLength);

        for (uint256 i = 0; i < strategiesLength;) {
            uint256 strategyDepositAmount = MathUtils.mulDiv(depositAmount, strategies[i].allocation, 100);

            requestKeys[i] = IRouter(payable(router)).createDeposit{value: executionFeePerDeposit}(
                strategies[i].marketId,
                address(this),
                tokenToSpend,
                strategyDepositAmount,
                executionFeePerDeposit,
                0,
                false
            );

            unchecked {
                ++i;
            }
        }

        depositRequests[depositKey] = OpenRequest({
            owner: msg.sender,
            amount: depositAmount,
            token: _token,
            timestamp: block.timestamp,
            requestKeys: requestKeys
        });

        openRequestKeys.add(depositKey);

        emit DepositCreated(depositKey, msg.sender, depositAmount, _token);
    }

    /**
     * @dev Important that this is only called after all deposits have been attempted.
     * @notice Role gated to prevent users from calling prematurely and causing valid
     * requests to be considered as failed.
     */
    function executeDeposit(bytes32 _openRequestKey) external nonReentrant onlyRoles(_ROLE_42) {
        OpenRequest storage request = depositRequests[_openRequestKey];
        if (request.owner == address(0)) revert YieldOptimizer_RequestNotFound();

        uint256 totalSuccessfulDeposits;
        uint256 failedAmount;
        uint256 successfulStrategies;

        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];

            try market.getRequest(strategy.marketId, request.requestKeys[i]) returns (Pool.Input memory input) {
                // Failed Case:
                // If the request still returns a value, it means the deposit has not been completed or failed.
                FailedRequest memory failedRequest = FailedRequest({
                    owner: request.owner,
                    requestKey: request.requestKeys[i],
                    marketId: strategy.marketId,
                    token: input.isLongToken ? weth : usdc,
                    amount: input.amountIn
                });

                failedAmount += input.amountIn;

                // Add the failed request to storage
                bytes32 failedRequestKey =
                    keccak256(abi.encodePacked(request.owner, request.requestKeys[i], strategy.marketId));
                failedRequests[failedRequestKey] = failedRequest;
                userFailedRequestKeys[request.owner].add(failedRequestKey);

                emit DepositFailed(_openRequestKey, address(strategy.vault), input.amountIn);
            } catch {
                // Success Case:
                // If the request reverts, it means the deposit hasbeen completed / wiped from storage.
                uint256 lpTokens = IVault(strategy.vault).depositMintAmounts(request.requestKeys[i]);
                uint256 depositAmount = request.amount * strategy.allocation / 100;

                totalSuccessfulDeposits += depositAmount;
                successfulStrategies++;

                emit DepositSucceeded(_openRequestKey, address(strategy.vault), depositAmount, lpTokens);
            }

            unchecked {
                ++i;
            }
        }

        if (totalSuccessfulDeposits > 0) {
            // Convert the total successful deposits into USD value to determine the amount of shares to mint
            uint256 shares = _calculateMintAmount(totalSuccessfulDeposits, request.token);

            _mint(request.owner, shares);

            emit SharesMinted(request.owner, shares, totalSuccessfulDeposits);
        }

        delete depositRequests[_openRequestKey];
        openRequestKeys.remove(_openRequestKey);

        emit DepositExecuted(_openRequestKey, request.owner, failedAmount, totalSuccessfulDeposits);
    }

    function createWithdrawal(address _token, uint256 _shares) external payable nonReentrant {
        if (!isDepositToken[_token]) revert YieldOptimizer_InvalidWithdrawalToken();

        if (withdrawalCooldowns[msg.sender] > block.timestamp) revert YieldOptimizer_WithdrawalCooldown();

        if (_shares > balanceOf[msg.sender]) revert YieldOptimizer_InsufficientShares();

        uint256 strategiesLength = strategies.length;

        if (msg.value < (executionFeePerDeposit * strategiesLength)) {
            revert YieldOptimizer_InsufficientExecutionFee();
        }

        bytes32[] memory requestKeys = new bytes32[](strategiesLength);

        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];

            requestKeys[i] = _createWithdrawalRequest(strategy, _shares, _token);

            unchecked {
                ++i;
            }
        }

        bytes32 withdrawalKey = _generateKey(msg.sender, _shares, _token, false);

        withdrawalRequests[withdrawalKey] = OpenRequest({
            owner: msg.sender,
            amount: _shares,
            token: _token,
            timestamp: block.timestamp,
            requestKeys: requestKeys
        });

        openRequestKeys.add(withdrawalKey);

        withdrawalCooldowns[msg.sender] = block.timestamp + cooldownDuration;

        emit WithdrawalCreated(withdrawalKey, msg.sender, _shares, _token);
    }

    /**
     * @dev Important that this is only called after all withdrawals have been attempted.
     * @notice Role gated to prevent users from calling prematurely and causing valid
     * requests to be considered as failed.
     */
    function executeWithdrawal(bytes32 _openRequestKey) external nonReentrant onlyRoles(_ROLE_42) {
        OpenRequest storage request = withdrawalRequests[_openRequestKey];
        if (request.owner == address(0)) revert YieldOptimizer_RequestNotFound();

        uint256 totalSuccessfulWithdrawals;
        uint256 totalReceivedWeth;
        uint256 totalReceivedUsdc;
        uint256 totalSuccessfulAllocation;

        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];
            uint256 strategyShares = MathUtils.mulDiv(request.amount, strategy.allocation, 100);

            try market.getRequest(strategy.marketId, request.requestKeys[i]) returns (Pool.Input memory input) {
                // Failed Case:
                // If the request still returns a value, it means the withdrawal has not been completed or failed.

                // Add the failed request to storage for later refund
                bytes32 failedRequestKey =
                    keccak256(abi.encodePacked(request.owner, request.requestKeys[i], strategy.marketId));

                failedRequests[failedRequestKey] = FailedRequest({
                    owner: request.owner,
                    requestKey: request.requestKeys[i],
                    marketId: strategy.marketId,
                    token: request.token == usdc ? usdc : weth,
                    amount: input.amountIn
                });
                userFailedRequestKeys[request.owner].add(failedRequestKey);

                emit WithdrawalFailed(_openRequestKey, address(strategy.vault), strategyShares);
            } catch {
                // Success Case:
                // If the request reverts, it means the withdrawal has been completed / wiped from storage.

                uint256 tokensOut = IVault(strategy.vault).withdrawalAmountOuts(request.requestKeys[i]);

                totalSuccessfulWithdrawals += strategyShares;

                if (request.token != usdc) {
                    totalReceivedWeth += tokensOut;
                } else {
                    totalReceivedUsdc += tokensOut;
                }

                totalSuccessfulAllocation += strategy.allocation;
                emit WithdrawalSucceeded(_openRequestKey, address(strategy.vault), tokensOut);
            }

            unchecked {
                ++i;
            }
        }

        if (totalSuccessfulWithdrawals > 0) {
            uint256 sharesToBurn = MathUtils.mulDiv(request.amount, totalSuccessfulAllocation, 100);

            _burn(request.owner, sharesToBurn);

            emit SharesBurned(request.owner, sharesToBurn, totalSuccessfulWithdrawals);
        }

        if (totalReceivedWeth > 0) {
            if (request.token == address(0)) {
                IWETH(weth).withdraw(totalReceivedWeth);
                SafeTransferLib.sendEthNoRevert(IWETH(weth), request.owner, totalReceivedWeth, 21000, owner());
            } else {
                IERC20(weth).safeTransfer(request.owner, totalReceivedWeth);
            }
        }
        if (totalReceivedUsdc > 0) {
            IERC20(usdc).safeTransfer(request.owner, totalReceivedUsdc);
        }

        delete withdrawalRequests[_openRequestKey];
        openRequestKeys.remove(_openRequestKey);

        emit WithdrawalExecuted(_openRequestKey, request.owner, totalReceivedWeth, totalReceivedUsdc);
    }

    function _createWithdrawalRequest(Strategy memory _strategy, uint256 _shares, address _token)
        private
        returns (bytes32 requestKey)
    {
        uint256 ownershipPercentage = MathUtils.divWad(_shares, totalSupply);

        uint256 tokensToWithdraw =
            MathUtils.mulWad(ownershipPercentage, IERC20(address(_strategy.rewardTracker)).balanceOf(address(this)));

        // This case is possible if a singular deposit reverts.
        // Without this check, the `createWithdrawal` function will revert.
        if (tokensToWithdraw == 0) return bytes32(0);

        IERC20(address(_strategy.rewardTracker)).approve(router, tokensToWithdraw);

        requestKey = IRouter(payable(router)).createWithdrawal{value: executionFeePerDeposit}(
            _strategy.marketId,
            address(this),
            _token == address(0) ? weth : _token,
            tokensToWithdraw,
            executionFeePerDeposit,
            _token == address(0)
        );
    }

    function _collectYield() private {
        uint256 totalWethYield;
        uint256 totalUsdcYield;

        uint256 strategiesLength = strategies.length;

        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];

            IRewardTracker rewardTracker = strategy.vault.rewardTracker();

            (uint256 wethAmount, uint256 usdcAmount) = rewardTracker.claim(address(this));

            totalWethYield += wethAmount;
            totalUsdcYield += usdcAmount;

            unchecked {
                ++i;
            }
        }

        accumulatedWethYield += totalWethYield;
        accumulatedUsdcYield += totalUsdcYield;

        emit YieldCollected(totalWethYield, totalUsdcYield);
    }

    function _calculateMintAmount(uint256 _amount, address _token) private view returns (uint256) {
        uint256 lpTokenPrice = getLpTokenPrice();

        string memory customId = _token == usdc ? "USDC:1" : "ETH:1";

        // Get the price of the token being transferred in
        uint256 tokenInPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), customId);

        if (tokenInPrice == 0) revert YieldOptimizer_LastPriceZero();

        // Get the base unit of the token
        uint256 baseUnit = _token == usdc ? 1e6 : 1e18;

        // Get the value of tokens in USD (e.g $2500 * 0.1e18 ETH / 1e18 = $250)
        uint256 tokenValueUsd = tokenInPrice.mulDiv(_amount, baseUnit);

        // Calculate the mint amount
        return tokenValueUsd.divWad(lpTokenPrice);
    }

    function _generateKey(address _owner, uint256 _amount, address _token, bool _isDeposit)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_owner, _amount, _token, block.timestamp, _isDeposit));
    }

    /**
     * @dev We take a weighted average instead of doing the aum / total supply approach,
     * as AUM would be reflected subject to a delay, depending on execution time.
     */
    function getLpTokenPrice() public view returns (uint256) {
        if (totalSupply == 0) {
            return 1e30;
        }

        uint256 longTokenPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), "ETH:1");
        uint256 shortTokenPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), "USDC:1");

        uint256 strategiesLength = strategies.length;
        uint256 weightedSum;

        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];
            uint256 indexPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), market.getTicker(strategy.marketId));
            int256 longPnl = MarketUtils.getMarketPnl(strategy.marketId, address(market), indexPrice, true);
            int256 shortPnl = MarketUtils.getMarketPnl(strategy.marketId, address(market), indexPrice, false);

            uint256 marketTokenPrice = MarketUtils.getMarketTokenPrice(
                address(strategy.vault), longTokenPrice, shortTokenPrice, longPnl + shortPnl
            );

            weightedSum += marketTokenPrice * strategy.allocation;
            unchecked {
                ++i;
            }
        }

        return weightedSum / 100;
    }

    /**
     * @dev Aum = cumulative value of all positions
     */
    function getAum() public view returns (uint256) {
        uint256 strategiesLength = strategies.length;
        uint256 totalAum;

        uint256 longTokenPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), "ETH:1");
        uint256 shortTokenPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), "USDC:1");

        for (uint256 i = 0; i < strategiesLength;) {
            Strategy memory strategy = strategies[i];

            // Get the last price from the price feed -> will be up to date from execution
            uint256 indexPrice = Oracle.getLastPrice(IPriceFeed(priceFeed), market.getTicker(strategy.marketId));

            // Get the pnl for the strategy
            int256 longPnl = MarketUtils.getMarketPnl(strategy.marketId, address(market), indexPrice, true);
            int256 shortPnl = MarketUtils.getMarketPnl(strategy.marketId, address(market), indexPrice, false);

            // Get the market token price for the strategy
            uint256 marketTokenPrice = MarketUtils.getMarketTokenPrice(
                address(strategy.vault), longTokenPrice, shortTokenPrice, longPnl + shortPnl
            );

            // Get the market tokens held for the strategy
            uint256 marketTokenHoldings = IRewardTracker(strategy.rewardTracker).balanceOf(address(this));

            // Sum up the aum for each strategy
            totalAum += MathUtils.mulWad(marketTokenPrice, marketTokenHoldings);

            unchecked {
                ++i;
            }
        }

        return totalAum;
    }

    function getStrategies() external view returns (Strategy[] memory) {
        return strategies;
    }

    function getFailedRequests(address _user) external view returns (FailedRequest[] memory) {
        bytes32[] memory failedRequestKeys = userFailedRequestKeys[_user].values();

        FailedRequest[] memory allFailedRequests = new FailedRequest[](failedRequestKeys.length);

        for (uint256 i = 0; i < failedRequestKeys.length; i++) {
            allFailedRequests[i] = failedRequests[failedRequestKeys[i]];
        }

        return allFailedRequests;
    }

    function getDepositRequest(bytes32 _key) external view returns (OpenRequest memory) {
        return depositRequests[_key];
    }

    function getWithdrawalRequest(bytes32 _key) external view returns (OpenRequest memory) {
        return withdrawalRequests[_key];
    }

    function getOpenRequests() external view returns (bytes32[] memory) {
        return openRequestKeys.values();
    }

    function getMaxWithdrawableAmount(address user, address token) public view returns (uint256) {
        // Get user's share balance
        uint256 userShares = balanceOf[user];
        if (userShares == 0) return 0;

        // Calculate ownership percentage
        uint256 ownershipPercentage = MathUtils.divWad(userShares, totalSupply);

        uint256 totalWithdrawable;

        // Loop through strategies to sum up available liquidity
        for (uint256 i = 0; i < strategies.length;) {
            Strategy memory strategy = strategies[i];

            // Get available liquidity from the vault
            uint256 availableLiquidity = token == usdc
                ? strategy.vault.totalAvailableLiquidity(false) // USDC
                : strategy.vault.totalAvailableLiquidity(true); // WETH/ETH

            // Calculate user's portion based on strategy allocation
            uint256 strategyAmount =
                MathUtils.mulWad(ownershipPercentage, availableLiquidity * strategy.allocation / 100);

            totalWithdrawable += strategyAmount;

            unchecked {
                ++i;
            }
        }

        return totalWithdrawable;
    }

    /**
     * @notice External getter function for encoding a uint8 array of allocation into a bytes string.
     */
    function encodeAllocations(uint8[] memory _allocs) external pure returns (bytes memory allocations) {
        allocations = new bytes(_allocs.length);

        for (uint256 i = 0; i < _allocs.length;) {
            allocations[i] = bytes1(_allocs[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice External getter function for decoding a bytes string into a uint8 array of allocations.
     */
    function decodeAllocations(bytes memory _allocations) external pure returns (uint8[] memory allocations) {
        allocations = new uint8[](_allocations.length);

        uint256 allocationsLength = _allocations.length;
        for (uint256 i = 0; i < allocationsLength;) {
            allocations[i] = uint8(_allocations[i]);

            unchecked {
                ++i;
            }
        }
    }
}
