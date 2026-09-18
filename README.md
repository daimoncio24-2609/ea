# ADX Trend Scalper EA (MQL5)

Expert Advisor for MetaTrader 5: `MQL5/Experts/ADX_Trend_Scalper_EA.mq5`

## Strategy

1. **Trend filter (H1):** ADX(14) on the H1 chart.
   - `DI+ > DI-` and `ADX > 25` → trend is **BUY**.
   - `DI- > DI+` and `ADX > 25` → trend is **SELL**.
   - Otherwise, no trend and no new trades are opened.
2. **Entry (M1 / M5 / M15):** on each new bar of the chosen entry timeframe, ADX is checked on that same timeframe. An order is opened only when its DI+/DI- bias agrees with the H1 trend direction, and only when there is no open basket yet (first entry of a cycle).
3. **Averaging (grid):** once a basket is open, an extra order in the same direction is added every `500` pips of adverse movement (measured from the worst-priced order in the basket), up to `10` open positions per basket. Averaging only continues while the **current** H1 trend still agrees with the basket's direction — if the H1 trend flips, the EA stops adding to that basket (it will not open new averaging orders against the new trend) and simply waits for the basket to reach its take-profit target.
4. **Exit:** since the strategy has no per-order stop loss (by design — it averages into the position), each basket is closed in full once price reaches the basket's volume-weighted average open price plus a small take-profit distance (default 20 pips). Without this, positions would never close.
5. **Time filter:** new entries and averaging adds only happen inside an allowed day-of-week + intraday time window (broker/server time). Existing baskets can still be closed by the take-profit rule at any time, even outside the window.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpADXPeriodH1` | 14 | ADX period on H1 |
| `InpADXTrendLevel` | 25.0 | ADX threshold that confirms a trend |
| `InpEntryTimeframe` | M15 | Entry timeframe: M1, M5, or M15 |
| `InpADXPeriodEntry` | 14 | ADX period on the entry timeframe |
| `InpLots` | 0.01 | Fixed lot size for every order (initial and averaging) |
| `InpAveragingPips` | 500 | Distance between averaging orders |
| `InpMaxAveragingOrders` | 10 | Max open orders per basket |
| `InpTakeProfitPips` | 20 | Basket close distance from average price |
| `InpMaxSpreadPoints` | 50 | Skip new/averaging entries if spread exceeds this |
| `InpMagicNumber` | 202609 | Magic number used to identify/manage this EA's orders |
| `InpSlippagePoints` | 10 | Max allowed slippage on order execution |
| `InpUseTimeFilter` | true | Enable the trading-hours filter |
| `InpStartHour` / `InpStartMinute` | 0 / 0 | Start of allowed trading window (broker/server time) |
| `InpEndHour` / `InpEndMinute` | 23 / 59 | End of allowed trading window (broker/server time); if start > end, the window wraps past midnight |
| `InpTradeMonday` … `InpTradeFriday` | true | Allow trading on that weekday |
| `InpTradeSaturday` / `InpTradeSunday` | false | Allow trading on that weekend day |

## Risk note

This is a martingale-style averaging strategy: with `InpAveragingPips = 500` and `InpMaxAveragingOrders = 10`, a basket can accumulate significant exposure (up to 5000 pips of adverse movement) before it stops adding orders. There is no hard basket stop loss — size `InpLots` and account balance accordingly.
