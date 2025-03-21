# PERMISSIONLESS PERPS

## General Overview

---

These smart contracts are designed to introduce a new type of perpetual futures market, where anyone can participate in the network as a keeper, and pricing can be supplied for almost any asset for which quotes can be fetched through CoinMarketCap, or other popular pricing services.

The overall architecture works as follows:

### Markets

Markets are created in a singleton pattern, to reduce the gas-overhead for creating new markets.

All new markets are created inside the `MarketFactory` smart contract.

Market creation occurs in 2 steps:

1. A Market is requested, and the user pays a small fee, and specifies all of the parameters necessary to create the new market.
2. The Market request is fulfilled, if valid pricing data can be fetched.

It is possible for a Market to be created with incorrect, or malicious information. In these cases, a trust score will be assigned to each market from front-ends, to give the user a clear indication for how trust-worthy a market is. Similarly to DexTools'.

Markets operate as virtual AMMs, where ETH / WETH is used to back long positions, and USDC is used to back short postions, no matter which asset is being traded.

There are 2 types of markets that can be created. A multi-asset market, or a single asset market. Multi-Asset markets are markets that support trading for multiple assets with 1 single source of liquidity, where traditional single asset markets involve 1 single asset, linked to a singular vault smart contract.

Multi-Asset markets are currently restricted so that they're only deployable by the contract administrator / protocol. They may become available to the general public after we weigh the associated risks.

**Requesting New Markets**

New Markets are first requested by a user through the `createNewMarket` function inside the `MarketFactory` smart contract.

The user is required to provide some input values, such as the ticker for the token they want to be traded in that market, the name and ticker of their LP token for that market, and also some details around the secondary pricing strategy.

Secondary pricing strategies are optional oracles, that can be configured to provide reference pricing for assets.

Provision of a valid secondary pricing strategy will boost the market's trust score, making it more likely to attract activity from users.

Secondary strategies can be any of the following:

- Chainlink Push Oracles
- Pyth Price Feeds
- Uniswap AMMs

Chainlink & pyth price feeds will provide a market a higher trust score, as Uniswap prices can be manipulated. Whenever an AMM is used for pricing, it's compulsory that one of the assets in the AMM is a stablecoin, which is validated by maintaining a merkle tree of valid stablecoin addresses on the `MarketFactory` smart contract.

**Executing New Markets**

Once a new market has been requested, users are incentivized to execute them and will capture a portion of the creation fee paid for doing so.

Execution will only go through if the Oracle is able to fetch a valid price, so cases in which an invalid ticker is provided will be unexecutable.

Once a market is executed, a `Vault` contract is deployed, which is responsible for storing all liquidity deposits associated with a market.

All of the data and storage associated with the Market is stored inside the singleton `Market` contract, under it's specific MarketId, which is generated from the input parameters.

The `MarketId` generated upon market creation is also used to associate trades created within the `TradeStorage` contract, and executed within the `TradeEngine` contract.

### Interacting with Markets

All user interactions come through 2 core contracts.

1. Router
2. PositionManager

**Router**

This contract is responsible for distributing all new user requests.

If a user wants to:

- Create a Deposit into a Vault
- Create a Withdrawal from a Vault
- Create a new Position Request

All of these interactions happen through this smart contract.

For each action, the user pays an over-estimated execution fee. A portion of this execution fee is rebated to the user, depending on how much of it is used by the keeper that executes the user's transaction.

**PositionManager**

This contract is responsible for the second-step, in which user requests are fulfilled.

Through this contract, keepers are able to:

- Execute Deposit requests into Vaults
- Execute Withdrawals from Vaults
- Excecute new Position Requests (Limit / Market Orders)
- Liquidate Positions
- ADL Markets at risk of insolvency.

Each of these actions has an associated rebate, which is paid to the keeper who executes it to incentivize market maintenance.

These rebates are generally percentage based, based either on the total fee associated with the action, or the total position reduction in the case of liquidations and ADLs.

### Trading

All data associated with trades is stored inside the `TradeStorage` smart contract.

All logic associated with executing trades is handled inside the `TradeEngine` smart contract.

There are 5 core categories that positions may fall under:

1. Create Position - creating a new position on a market.
2. Increase Position - increasing an existing position on a market.
3. Decrease Position - decreasing an existing position on a market.
4. Collateral Adjustment - adjusting the amount of margin held by a position (increase / decrease)
5. Conditional Order - stop loss or take profit orders to reduce a positions size once a certain condition is met.

Positions can be created as Limit orders (will execute at a certain time in the future), or Market orders (to execute instantly).

As Market orders are subject to a 2-step mechanism, the timestamp at which the request is created at is stored onchain. Upon execution, the trade is executed using pricing data from the exact timestamp at which the request was created.

As Limit orders are designed to execute in the future, once a certain condition is met, they are instead executed at the current market price of that specific asset.

**Stop Loss and Take Profits**

Stop Loss and Take Profit orders can be created, and are technically stored onchain the same as Limit Orders are. However, to prevent the issue of a SL/TP order remaining onchain after the associated position no longer exists, they are perpetually tied together.

Positions store the keys (bytes32 signatures) of associated SL/TP orders, so if the position is fully reduced, the SL/TP orders associated with it are also cleared from storage.

Stop Loss and Take Profit orders can either be created:

- At the same time as the Position is being created
- After a position already exists

If a user wants to create a SL / TP order at the same time as a position is created, they can optionally provide a non-empty `Conditionals` struct. This struct lets them specify:

- If the order (SL/TP) should exist
- What price the order should be fulfilled at
- What percentage the order should reduce the position by

**Trading Fees**

All positions are subject to a fixed 0.01% trading fee.

**Borrowing Fees**

The borrowing fee is calculated depending on how close the pool is to maximum open interest capacity. The higher the demand for open interest on a pool, the higher the borrowing fee charged to active traders. Conversely, if there's plenty of open interest available on a pool, the borrowing fees charged on active positions will be negligible.

The borrowing rate calculation is simply:

`borrowRate = borrowFeeScale * (openInterest / maxOpenInterest)`

For example, if the borrowFeeScale is set to 0.01%, that is the maximum possible borrow fee that will be charged on a given day.

Depending on the ratio of open interest compared with the maximum open interest, borrowing fees will be anywhere between 0 and the borrowFeeScale.

The units of the borrowing rate are percentage per day. So a position with $100 in size, open for 24 hours, at a 0.001% borrowing rate, will be charged $0.001 per day.

**Funding Fees**

Funding fees are designed to incentivize a balance between long and short positions, so that they offset eachothers gains / losses, and maximize market solvency.

Funding fees are adapted from Synthetix's dynamic funding mechanism: https://blog.synthetix.io/synthetix-perps-dynamic-funding-rates/

Each market features a funding velocity defined by the formula `dr/dt = c * skew`, where dr/dt represents the rate of change of the funding rate over time, c is a constant factor, and skew is the difference between long and short open interest.

The greater the skew between long and short open interest, the more intense the funding velocity will be.

c is calculated as `maxFundingVelocity * (skew / skewScale)` where skew = Δ(longOpenInterest, shortOpenInterest), and skewScale is the scale upon which skew is charged.

**PriceImpact**

Price impact is another mechanism designed to incentivize balance between long and short positions.

It is determined by how much the action impacts the skew of the market.

Price impact can be both positive, where the trader is given a more favourable price, and negative, where the trader is given a less favourable price.

Any action that skews the market unfavourably will face negative price impact.

Any action that balances the market will be positively impacted.

Positive price impact is capped by the impact pool, which is a portion of the liquidity pool that accounts for the accumulated value of negative impact that has been applied to positions.

Price Impact: Price impact is calculated using the following formula:

`PriceImpact = sizeDelta * α((initSkew/initialTotalOi) - (updatedSkew/updatedTotalOi)) * β(sizeDelta/totalAvailableLiquidity)`

Where α = skewScalar (a dampening factor that can be applied to minimize the impact of skew) and β = liquidityScalar (a dampening factor that can be applied to minimize the impact of illiquidity). The less liquid and more skewed the market, the higher the price impact, and vice versa. Alpha and Beta can be configured on a per-market basis depending on market conditions.

**Liquidations**

Liquidations simply occur when the collateral of a position is no longer sufficient to cover any losses accrued. These losses may be accrued in the form of Pnl or accumulated fees.

In the event of a liquidation, a percentage of the liquidated collateral is paid to the user as an incentive for keeping markets solvent.

A maintenanceMargin value is configured to ensure liquidations are able to occur slightly before the position reaches the point of insolvency.

In the event of insolvent liquidations, losses are paid off in order of priority until the collateral is exhausted, first covering the liquidation fee to ensure the liquidator is always incentivised.

**ADLs**

To ensure market solvency during times of extreme volatility, perpetual futures markets created through the Print3r protocol feature auto-deleveraging (ADL).

ADLs are triggered when a market becomes highly profitable, putting the pool at risk of insolvency. A default threshold is set at a 45% PnL to pool ratio. Once this threshold is reached, ADLs can be undertaken on the most profitable positions in the market to bring the PnL to pool ratio back down to a healthy level.

Users who perform the ADLs are compensated with a percentage of the total size that is de-leveraged, incentivizing them to target the positions that contribute most significantly to the PnL to pool ratio.

The formula to calculate the percentage of the position to ADL is:

`percentageToAdl = 1 - ((pnl / size) * (e ** (-excessRatio**2)))`

Where:

`excessRatio = (currentPnltoPoolRatio / targetPnlToPoolRatio) - 1`

**Gas Rebates**

As keepers are separate autonomous entities from the user, they require gas to execute transactions. To keep the system running at net zero cost, users are required to forward the necessary gas to the keeper along with their request.

Based on the gas price at the time of the request and the computation required for the user's given action, a predicted execution fee will be applied to the position, which can be retrieved by calling `Gas.estimateExecutionFee`.

By keeping track of the execution fee paid by the user and subtracting the amount of gas actually consumed from the provided fee at the end of the transaction, the keeper will rebate any excess gas back to the user. This ensures that the user only pays the minimum amount of gas necessary, essentially akin to the amount of gas the user would have consumed if they had performed all the computation themselves.

To calculate the ether spent on gas for the keeper’s transaction, we follow these steps: 1. Store the initial gas at the very beginning of the transaction.

1. `initialGas = gasleft()`

2. Subtract the remaining gas at the very end of the transaction . `executionCost = (initialGas - gasleft()) * tx.gasprice`

3. Rebate the user the delta between the amount paid, and the actual execution cost `feeToRefund = executionFeePaid - actualExecutionCost`

### Liquidity Provision

Liquidity associated with markets are stored in separate `Vault` smart contracts.

Liquidity is stored separately for long and short positions, with long liquidity being stored as Wrapped Ether (WETH), and short liquidity being stored as USDC.

This is designed to protect liquidity providers against market volatility, as generally, markets move proportionally, so if long positions are profitable, the long liquidity should theoretically be more valuable too, minimizing the harm of any profit payout.

Conversely, if short positions are profitable, the value of the liquidity should remain stable, ensuring that the market remains solvent to pay out any profit. If we were to use WETH here, the WETH would theoretically become less valuable as short positions before more profitable, increasing the harm of any profit payouts.

Liquidity is deposited and withdrawn subject to a 2 step mechanism.

1. A request is created with the intent.
2. The request is fulfilled / executed.

Intermediate funds are stored within the `PositionManager` smart contract, before being added to the `Vault` if the execution is successful.

To incentivise an equal balance between the USD value of long and short liquidity, deposits / withdrawals are subject to a dynamic fee. This fee is calculated through `MarketUtils.calculateDepositFee` for deposits and `MarketUtils.calculateWithdrawalFee` for withdrawals.

Fees are charged along a scale, `FEE_SCALE`, which represents the absolute maximum fee charged to a position.

If a deposit / withdrawal damages the balance between long and short liquidity, it is charged a greater portion of the fee scale.

If a deposit / withdrawal creates more balance between long and short liquidity, it is charged a lesser portion of the fee scale.

The total fee charged for a deposit or withdrawal is calculated as follows:

- Base Fee: A minimal fee charged to each position, calculated by multiplying the sizeDelta by the fee percentage (e.g 1 ETH \* 0.0001 = 0.0001 ETH).
- Dynamic Fee: An additional fee charged based on how the action affects the skew between long/short value.

The formula is:

`dynamicFee = sizeDelta * ((ΔnegativeSkewAccrued * feeScale) / ΣpoolValue)`

The total fee charged to the position is baseFee + dynamicFee.

### Rewards

Fees are accumulated by markets from trading fees and fees associated with adding / withdrawing liquidity. These fees are accumulated in WETH for long positions, and USDC for short positions.

Fees are paid out equally, from both pools to all liquidity providers. This is designed to incentivize balance in the deposit of assets within the market.

Fees are distributed based on the amount of market tokens a user holds, so by holding market tokens associated with a vault, a user will accumulate both long fees (denominated in WETH) and short fees (denominated in USDC).

A total of 80% of all fees generated are distributed to the `RewardTracker` contract. This singleton contract is responsible for determining rates of rewards, and distributing those rewards to liquidity providers.

10% of the total fees generated by a market will be distributed to the deployer of that liquidity pool. This is designed to incentivize users to create new markets and abide by the rules, so that they can attract new traders and liquidity providers to their pools and be fiscally compensated for doing so.

The remaining 10% will be distributed to the protocol.

In the case where bad-debt is accumulated by the protocol, this will be deducted from the fees distributed to the protocol / pool deployers. Bad debt is not settled from fees accumulated by liquidity providers, as to not disincentivize active provision of liquidity.

### Referrals

Referral codes can be generated within the `ReferralStorage` smart contract.

Referral codes are arranged into 3 tiers, with each subsequent tier providing a greater trading fee discount / rebate to the referrer.

When a referral code is used, a percentage is deducted from the trading fee, 50% of which goes to providing a fee discount to the user, and 50% of which goes towards incentivizing the affiliate.

Rebates are accumulated in whichever token the trading fee is collected in.

Rebates can be claimed in real-time from the `ReferralStorage` smart contract by calling the `claimAffiliateRewards` function.

### In Scope Assets:

| Filepath                          | nSLOC    |
| --------------------------------- | -------- |
| src/factory/Deployer.sol          | 40       |
| src/factory/MarketFactory.sol     | 259      |
| src/libraries/Borrowing.sol       | 108      |
| src/libraries/Funding.sol         | 82       |
| src/libraries/Gas.sol             | 85       |
| src/libraries/PriceImpact.sol     | 222      |
| src/markets/Market.sol            | 351      |
| src/markets/MarketUtils.sol       | 481      |
| src/markets/Pool.sol              | 211      |
| src/markets/Vault.sol             | 227      |
| src/oracle/Oracle.sol             | 367      |
| src/oracle/PriceFeed.sol          | 381      |
| src/positions/Execution.sol       | 633      |
| src/positions/Position.sol        | 398      |
| src/positions/TradeEngine.sol     | 481      |
| src/positions/TradeStorage.sol    | 188      |
| src/referrals/Referral.sol        | 18       |
| src/referrals/ReferralStorage.sol | 124      |
| src/rewards/FeeDistributor.sol    | 85       |
| src/rewards/RewardTracker.sol     | 250      |
| src/router/PositionManager.sol    | 176      |
| src/router/Router.sol             | 284      |
| **Total**                         | **5757** |
