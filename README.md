# ADX Trend Scalper EA (MQL5)

Expert Advisor for MetaTrader 5: `MQL5/Experts/ADX_Trend_Scalper_EA.mq5`

## Strategy

1. **Trend filter (H1):** ADX(14) on the H1 chart.
   - `DI+ > DI-` and `ADX > 25` → trend is **BUY**.
   - `DI- > DI+` and `ADX > 25` → trend is **SELL**.
   - Otherwise, no trend and no new trades are opened.
2. **Entry (M1 / M5 / M15):** on each new bar of the chosen entry timeframe, ADX is checked on that same timeframe. An order is opened in the H1 trend's direction only when its DI+/DI- bias agrees with that direction, and only when there is no basket already open on that side (BUY and SELL baskets are tracked independently).
3. **Trend flip → new basket, old basket keeps waiting:** BUY and SELL each have their own basket. When H1 flips trend, a fresh basket is opened straight away on the new side (per point 2), while any basket still open on the other side is left as-is: it is **not** closed and does **not** get new averaging orders while H1 disagrees with it. If H1 later swings back to agree with that older basket, it resumes averaging (point 4) right where it left off. This means BUY and SELL baskets can be open on the same symbol at the same time (hedging), each managed independently.
4. **Averaging (grid):** once a basket is open, an extra order in the same direction is added every `500` pips of adverse movement (measured from the worst-priced order in that basket), up to `10` open positions per basket (`InpMaxAveragingOrders` applies per side, so BUY and SELL can each hold up to that many). Averaging only continues while the **current** H1 trend still agrees with the basket's direction.
5. **Exit:** since the strategy has no per-order stop loss (by design — it averages into the position), each basket (BUY and SELL independently) is closed in full once price reaches that basket's volume-weighted average open price plus a small take-profit distance (default 20 pips). Without this, positions would never close.
6. **Time filter:** new entries and averaging adds only happen inside an allowed day-of-week + intraday time window (broker/server time). On Fridays the window closes earlier (default 14:00) to reduce weekend-gap exposure, regardless of the general end time. Existing baskets can still be closed by the take-profit rule at any time, even outside the window.

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
| `InpUseFridayEarlyClose` | true | On Friday, use `InpFridayEndHour`/`InpFridayEndMinute` instead of `InpEndHour`/`InpEndMinute` as the cutoff for new entries |
| `InpFridayEndHour` / `InpFridayEndMinute` | 14 / 0 | Friday-only cutoff time for new entries/averaging (broker/server time) |

## Risk note

This is a martingale-style averaging strategy: with `InpAveragingPips = 500` and `InpMaxAveragingOrders = 10`, a single basket can accumulate significant exposure (up to 5000 pips of adverse movement) before it stops adding orders. There is no hard basket stop loss — size `InpLots` and account balance accordingly. Because BUY and SELL baskets are independent, both sides can be open (hedged) at once on trend flips, so worst-case exposure/margin usage is up to double a single basket's.
