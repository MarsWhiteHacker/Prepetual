###Description:

- Liquidity Providers can deposit and withdraw liquidity.
  1. deposit USDC/WBTC
  2. withdraw USDC/WBTC
- A way to get the realtime price of the asset being traded.
  1. Connect Chainlink price feed
- Traders can open a perpetual position for BTC, with a given size and collateral.
- Traders can increase the size of a perpetual position.
- Traders can increase the collateral of a perpetual position.
- Traders cannot utilize more than a configured percentage of the deposited liquidity.
- Liquidity providers cannot withdraw liquidity that is reserved for positions.

- Traders can decrease the size of their position and realize a proportional amount of their PnL.
- Traders can decrease the collateral of their position.
- Individual position’s can be liquidated with a `liquidate` function, any address may invoke the `liquidate` function.
- A `liquidatorFee` is taken from the position’s remaining collateral upon liquidation with the `liquidate` function and given to the caller of the `liquidate` function.
- Traders can never modify their position such that it would make the position liquidatable.
- Traders are charged a `borrowingFee` which accrues as a function of their position size and the length of time the position is open.

###Coverage:
![image](https://github.com/MarsWhiteHacker/Prepetual/assets/98659734/91834f54-fae2-4c0f-ba65-40ae9e3cbbfd)


