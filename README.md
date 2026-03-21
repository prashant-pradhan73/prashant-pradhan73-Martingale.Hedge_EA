# MartingaleHedge EA for MetaTrader 5

Martingale strategy for forex Gold (XAUUSD) trading with an automatic hedge
mechanism to protect against excessive drawdown.

---

## Strategy overview

1. **Entry signal** — A Buy/Sell trade is opened when the fast EMA crosses
   above/below the slow EMA on the chosen timeframe.
2. **Martingale grid** — If price moves `InpMartingaleGap` points against the
   open position(s), a new position is added with a lot size multiplied by
   `InpLotMultiplier`.  This continues up to `InpMaxSteps` levels.
3. **Hedge protection** — When the account drawdown (as a percentage of
   balance) exceeds `InpHedgeDrawdown`, an opposing position is opened with
   a lot equal to the total open lots × `InpHedgeLotFactor`.  Once the
   drawdown recovers to half the trigger level **and** the hedge is
   profitable, the hedge is closed automatically.
4. **Reversal** — When an opposite EMA crossover is detected and
   `InpCloseOnOpposite` is enabled, all positions are closed and the EA
   enters in the new direction.

---

## Input parameters

### Trade Settings
| Parameter | Default | Description |
|---|---|---|
| `InpInitialLot` | 0.01 | Starting lot size for the first trade |
| `InpLotMultiplier` | 2.0 | Multiplier applied to lot size at each Martingale step |
| `InpMaxSteps` | 6 | Maximum number of Martingale additions |
| `InpMaxLot` | 5.0 | Absolute cap on a single position's lot size |
| `InpTakeProfit` | 500 | Take Profit in points (0 = disabled) |
| `InpStopLoss` | 0 | Stop Loss in points (0 = disabled) |
| `InpMagicNumber` | 20241 | Unique identifier for this EA's orders |
| `InpComment` | "MH_EA" | Comment prefix attached to every order |

### Martingale Settings
| Parameter | Default | Description |
|---|---|---|
| `InpMartingaleGap` | 500 | Points of adverse move before adding the next grid level |

### Hedge Settings
| Parameter | Default | Description |
|---|---|---|
| `InpUseHedge` | true | Enable/disable hedge protection |
| `InpHedgeDrawdown` | 5.0 | Drawdown % that triggers the hedge |
| `InpHedgeLotFactor` | 1.5 | Hedge lot = total open lots × this factor |
| `InpHedgeTP` | 300 | Take Profit for the hedge position in points |

### Signal Settings
| Parameter | Default | Description |
|---|---|---|
| `InpTimeframe` | H1 | Timeframe used for EMA crossover detection |
| `InpFastMA` | 10 | Fast EMA period |
| `InpSlowMA` | 20 | Slow EMA period |
| `InpCloseOnOpposite` | true | Close all positions on an opposite crossover |

---

## Installation

1. Copy `MartingaleHedge_EA.mq5` to the MetaTrader 5 `Experts` folder
   (usually `<MT5 data folder>/MQL5/Experts/`).
2. Open MetaEditor, locate the file and click **Compile** (F7).
3. Attach the EA to an **XAUUSD** chart.
4. Ensure **AutoTrading** is enabled in the MT5 toolbar.
5. Adjust the input parameters as required and click **OK**.

---

## Risk warning

The Martingale strategy can lead to rapid account drawdown if the market
trends strongly against open positions.  Always test on a demo account
before using real funds, and use conservative lot sizes and a strict
`InpMaxSteps` limit.
