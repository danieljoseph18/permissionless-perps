Traces:
[410601] TestGetAumYieldOp::test_get_lp_token_price()
├─ [0] VM::selectFork(0)
│ └─ ← [Return]
├─ [397164] 0x1371aF468464FfC811D974A93bc60b5837242e38::getLpTokenPrice() [staticcall]
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("ETH:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x4554483a3100000000000000000000, precision: 13, variance: 0, timestamp: 1733464680 [1.733e9], med: 38894556449781616 [3.889e16] })
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("USDC:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x555344433a31000000000000000000, precision: 15, variance: 0, timestamp: 1733464680 [1.733e9], med: 1000085453869768 [1e15] })
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d) [staticcall]
│ │ └─ ← [Return] "BTC:1"
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("BTC:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x4254433a3100000000000000000000, precision: 11, variance: 0, timestamp: 1733464680 [1.733e9], med: 9786107838582712 [9.786e15] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 97861078385827120000000000000000000 [9.786e34], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 97861078385827120000000000000000000 [9.786e34], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xd6e84a6b4671d927b7454570d863761bd0efd167c502407a08e196f9c1b5332d) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0x70be6ceFC4E50a45083468241487e6B1613191E8, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0x70be6ceFC4E50a45083468241487e6B1613191E8::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 668088254638926345736 [6.68e20]
│ │ ├─ [2397] 0x70be6ceFC4E50a45083468241487e6B1613191E8::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 59940000000000002 [5.994e16]
│ │ ├─ [2353] 0x70be6ceFC4E50a45083468241487e6B1613191E8::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 432729152 [4.327e8]
│ │ └─ ← [Return] 996724754726427406876218081951 [9.967e29]
│ ├─ [2588] 0xaF00c80acB5182Ef0Dd9987dE8e7243339AAf475::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 451062499841053827702 [4.51e20]
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109) [staticcall]
│ │ └─ ← [Return] "ETH:1"
│ ├─ [1769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("ETH:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x4554483a3100000000000000000000, precision: 13, variance: 0, timestamp: 1733464680 [1.733e9], med: 38894556449781616 [3.889e16] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 3889455644978161600000000000000000 [3.889e33], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 3889455644978161600000000000000000 [3.889e33], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xf94ec62d5d5fc25eddbb97c882dfc4ba9b700ff8a4099ff60b97c78e520b1109) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0x6d3717DBaA9Dac308F1E1D82d0365693A3bd10bc, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0x6d3717DBaA9Dac308F1E1D82d0365693A3bd10bc::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 378581805636771191666 [3.785e20]
│ │ ├─ [2397] 0x6d3717DBaA9Dac308F1E1D82d0365693A3bd10bc::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 39960000000000002 [3.996e16]
│ │ ├─ [2353] 0x6d3717DBaA9Dac308F1E1D82d0365693A3bd10bc::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 221969168 [2.219e8]
│ │ └─ ← [Return] 996906819288107587024382505611 [9.969e29]
│ ├─ [2588] 0x6E06Cb62e35Cc57E25D93A1EC0BA9CC6bcc67725::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 300706002314520757529 [3.007e20]
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42) [staticcall]
│ │ └─ ← [Return] "SOL:1"
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("SOL:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x534f4c3a3100000000000000000000, precision: 14, variance: 0, timestamp: 1733464680 [1.733e9], med: 23882334210986196 [2.388e16] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 238823342109861960000000000000000 [2.388e32], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 238823342109861960000000000000000 [2.388e32], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xd15bfd2810ca1f985a01c30aaee2a7ae54b4307f653e2718e2fa7a71ee489a42) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0x11D9eCcc31438dbbfbe3aa275cb68067d0767625, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0x11D9eCcc31438dbbfbe3aa275cb68067d0767625::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 378578445503516603773 [3.785e20]
│ │ ├─ [2397] 0x11D9eCcc31438dbbfbe3aa275cb68067d0767625::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 39960000000000002 [3.996e16]
│ │ ├─ [2353] 0x11D9eCcc31438dbbfbe3aa275cb68067d0767625::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 221969168 [2.219e8]
│ │ └─ ← [Return] 996915667493268237930533869812 [9.969e29]
│ ├─ [2588] 0xb4647F8880E78EBaa46A98A5B124858A02E0f4ab::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 300703333374219911056 [3.007e20]
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee) [staticcall]
│ │ └─ ← [Return] "XRP:1"
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("XRP:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x5852503a3100000000000000000000, precision: 16, variance: 0, timestamp: 1733464680 [1.733e9], med: 23665267269485524 [2.366e16] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 2366526726948552400000000000000 [2.366e30], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 2366526726948552400000000000000 [2.366e30], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0x33cd6aed79bc29287f45803b1a1707fc1a192c5f983780ea7b114b1d5b4394ee) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0xF7C8115b3ADe6ab845d5be859CAA686885200A82, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0xF7C8115b3ADe6ab845d5be859CAA686885200A82::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 149939999308043494961 [1.499e20]
│ │ ├─ [2397] 0xF7C8115b3ADe6ab845d5be859CAA686885200A82::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 9990000000000000 [9.99e15]
│ │ ├─ [2353] 0xF7C8115b3ADe6ab845d5be859CAA686885200A82::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 110983458 [1.109e8]
│ │ └─ ← [Return] 999390453186827356530901676255 [9.993e29]
│ ├─ [2588] 0xd5f34fe070eBb42afE22FEFd8Bf9F9B4546C7e0f::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 149939999308043494961 [1.499e20]
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66) [staticcall]
│ │ └─ ← [Return] "DOGE:1"
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("DOGE:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x444f47453a31000000000000000000, precision: 17, variance: 0, timestamp: 1733464680 [1.733e9], med: 43538893684308016 [4.353e16] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 435388936843080160000000000000 [4.353e29], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 435388936843080160000000000000 [4.353e29], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0xe6261dd7b4e32a6201918d44d41275eba64e1f0bc158eff02e192e8217aebe66) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0xD2D19FE607c99B28c79A741Fa457Ad5438eD4325, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0xD2D19FE607c99B28c79A741Fa457Ad5438eD4325::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 150354087847138973519 [1.503e20]
│ │ ├─ [2397] 0xD2D19FE607c99B28c79A741Fa457Ad5438eD4325::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 9990000000000000 [9.99e15]
│ │ ├─ [2353] 0xD2D19FE607c99B28c79A741Fa457Ad5438eD4325::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 110983458 [1.109e8]
│ │ └─ ← [Return] 996638042935322669476418715992 [9.966e29]
│ ├─ [2588] 0x4DB4CCb754c1c2506fC1f79c250604cB5ee861CE::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 111416186186013758399 [1.114e20]
│ ├─ [3455] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getTicker(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536) [staticcall]
│ │ └─ ← [Return] "SUI:1"
│ ├─ [3769] 0x78362f497C26216B70e646306BDCE9347Fcc95f5::getLastPrice("SUI:1") [staticcall]
│ │ └─ ← [Return] Price({ ticker: 0x5355493a3100000000000000000000, precision: 15, variance: 0, timestamp: 1733464680 [1.733e9], med: 4295070673520031 [4.295e15] })
│ ├─ [17828] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 4295070673520031000000000000000 [4.295e30], true) [delegatecall]
│ │ ├─ [2652] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536, true) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [13524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [5859] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketPnl(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536, 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc, 4295070673520031000000000000000 [4.295e30], false) [delegatecall]
│ │ ├─ [2662] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getOpenInterest(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536, false) [staticcall]
│ │ │ └─ ← [Return] 0
│ │ ├─ [1524] 0xC357C293d3B9FaFD320C8c1eA59Af2083C011FEc::getCumulatives(0x19fa48b3a7c8f7d0521518279350ed1cf7d0c48f3223a55bf9e983be3a0c9536) [staticcall]
│ │ │ └─ ← [Return] Cumulatives({ longAverageEntryPriceUsd: 0, shortAverageEntryPriceUsd: 0, longCumulativeBorrowFees: 0, shortCumulativeBorrowFees: 0, weightedAvgCumulativeLong: 0, weightedAvgCumulativeShort: 0 })
│ │ └─ ← [Return] 0
│ ├─ [11960] 0xe4eBe84dcf843AFdA354Fa09f69e6471131ba55c::getMarketTokenPrice(0x3fb776585C5172508cbAf7DE3f03D2388c60891C, 3889455644978161600000000000000000 [3.889e33], 1000085453869768000000000000000 [1e30], 0) [delegatecall]
│ │ ├─ [2375] 0x3fb776585C5172508cbAf7DE3f03D2388c60891C::totalSupply() [staticcall]
│ │ │ └─ ← [Return] 189286528989941394199 [1.892e20]
│ │ ├─ [2397] 0x3fb776585C5172508cbAf7DE3f03D2388c60891C::longTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 19980000000000000 [1.998e16]
│ │ ├─ [2353] 0x3fb776585C5172508cbAf7DE3f03D2388c60891C::shortTokenBalance() [staticcall]
│ │ │ └─ ← [Return] 110984586 [1.109e8]
│ │ └─ ← [Return] 996929865299868712212179705789 [9.969e29]
│ ├─ [2588] 0x18E915531B9d563D55D9A280059b39946c9609f0::balanceOf(0x1371aF468464FfC811D974A93bc60b5837242e38) [staticcall]
│ │ └─ ← [Return] 150348627328816179079 [1.503e20]
│ └─ ← [Return] 2225973378334049837398722020052 [2.225e30]
├─ [0] console::log("Price: ", 2225973378334049837398722020052 [2.225e30]) [staticcall]
│ └─ ← [Stop]
└─ ← [Stop]
