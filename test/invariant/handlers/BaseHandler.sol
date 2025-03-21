// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Router} from "src/router/Router.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {Market} from "src/markets/Market.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {Vault} from "src/markets/Vault.sol";
import {MarketId} from "src/types/MarketId.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {Execution} from "src/positions/Execution.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";

abstract contract BaseHandler is Test {
    using MathUtils for uint256;

    struct PositionDetails {
        uint256 size;
        uint256 leverage;
        bytes32 key;
    }

    Router public router;
    PositionManager public positionManager;
    TradeStorage public tradeStorage;
    Market public market;
    MockPriceFeed public priceFeed;
    Vault public vault;

    string public ethTicker = "ETH:1";
    address public weth;
    address public usdc;
    MarketId public marketId;

    uint8[] public precisions;
    uint16[] public variances;
    uint48[] public timestamps;
    uint64[] public meds;
    string[] public tickers;

    address public user0 = vm.addr(uint256(keccak256("User0")));
    address public user1 = vm.addr(uint256(keccak256("User1")));
    address public user2 = vm.addr(uint256(keccak256("User2")));
    address public user3 = vm.addr(uint256(keccak256("User3")));
    address public user4 = vm.addr(uint256(keccak256("User4")));
    address public user5 = vm.addr(uint256(keccak256("User5")));

    address[6] public actors;

    receive() external payable {}

    constructor(
        address _weth,
        address _usdc,
        address payable _router,
        address payable _positionManager,
        address _tradeStorage,
        address _market,
        address payable _vault,
        address _priceFeed,
        MarketId _marketId
    ) {
        weth = _weth;
        vm.label(weth, "weth");
        usdc = _usdc;
        vm.label(usdc, "usdc");
        router = Router(_router);
        positionManager = PositionManager(_positionManager);
        tradeStorage = TradeStorage(_tradeStorage);
        market = Market(_market);
        priceFeed = MockPriceFeed(payable(_priceFeed));
        vault = Vault(_vault);
        marketId = _marketId;

        tickers.push("ETH:1");
        tickers.push("USDC:1");

        precisions.push(0);
        precisions.push(0);

        variances.push(0);
        variances.push(0);

        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));

        meds.push(3000);
        meds.push(1);

        actors[0] = user0;
        vm.label(user0, "user0");

        actors[1] = user1;
        vm.label(user1, "user1");

        actors[2] = user2;
        vm.label(user2, "user2");

        actors[3] = user3;
        vm.label(user3, "user3");

        actors[4] = user4;
        vm.label(user4, "user4");

        actors[5] = user5;
        vm.label(user5, "user5");
    }

    modifier passTime(uint256 _timeToSkip) {
        _timeToSkip = bound(_timeToSkip, 1, 36500 days);
        _;
    }

    function _updateEthPrice(uint256 _price) internal {
        meds[0] = uint64(_price);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
    }

    function _deal(address _user) internal {
        deal(_user, 100_000_000 ether);
        deal(weth, _user, 100_000_000 ether);
        deal(usdc, _user, 300_000_000_000e6);
    }

    function randomAddress(uint256 seed) internal view returns (address) {
        return actors[_bound(seed, 0, actors.length - 1)];
    }

    function _getAvailableOi(uint256 _indexPrice, bool _isLong) internal view returns (uint256) {
        return MarketUtils.getAvailableOiUsd(
            marketId, address(market), address(vault), _indexPrice, _isLong ? _indexPrice : 1e30, _isLong
        );
    }
}
