# ADX Trend Scalper EA (MQL5)

Expert Advisor for MetaTrader 5: `MQL5/Experts/ADX_Trend_Scalper_EA.mq5`

## Strategy

1. **Trend filter (H1):** ADX(14) on the H1 chart.
   - `DI+ > DI-` and `ADX > 25` → trend is **BUY**.
   - `DI- > DI+` and `ADX > 25` → trend is **SELL**.
   - Otherwise, no trend and no new trades are opened.
   - The DI+/DI- gap must also clear `InpMinDISpreadH1` (default 5) — a razor-thin cross, won by a fraction of a point, doesn't count as a real trend.
2. **Entry (M1 / M5 / M15):** on each new bar of the chosen entry timeframe, its DI+/DI- bias is evaluated with three quality filters aimed at cutting down whipsaw entries on the (noisier) lower timeframe: (a) ADX on the entry timeframe must clear `InpADXMinLevelEntry` (default 20) — a bare DI cross during a flat/choppy stretch is rejected; (b) the DI+/DI- gap must clear `InpMinDISpreadEntry` (default 5) — same razor-thin-cross rejection as the H1 filter; (c) the (qualifying) cross must be **fresh** — the previous closed bar must not already have qualified, so a signal only fires right as the cross happens, not on every later bar where it happens to still hold (which is usually a late entry). An order is opened in the H1 trend's direction only when this filtered bias agrees with that direction, and only when there is no basket already open on that side (BUY and SELL baskets are tracked independently). Trade-off: because the fresh-cross requirement is timed by the entry timeframe, a basket may not open on the exact tick the H1 trend flips — it waits for the entry timeframe's own next qualifying cross.
3. **Trend flip → new basket, old basket keeps waiting:** BUY and SELL each have their own basket. When H1 flips trend, a fresh basket is opened straight away on the new side (per point 2), while any basket still open on the other side is left as-is: it is **not** closed and does **not** get new averaging orders while H1 disagrees with it. If H1 later swings back to agree with that older basket, it resumes averaging (point 4) right where it left off. This means BUY and SELL baskets can be open on the same symbol at the same time (hedging), each managed independently.
4. **Averaging (grid):** once a basket is open, an extra order in the same direction is added every *averaging distance* of adverse movement (measured from the worst-priced order in that basket), up to `5` open positions per basket (`InpMaxAveragingOrders` applies per side, so BUY and SELL can each hold up to that many). Averaging only continues while the **current** H1 trend still agrees with the basket's direction. The distance is **not** a hardcoded "pip" — see the note below on `InpAveragingMode`.
5. **Exit:** since the strategy has no per-order stop loss (by design — it averages into the position), each basket (BUY and SELL independently) is closed in full once price reaches that basket's volume-weighted average open price plus a take-profit distance (`InpTakeProfitMode`: ATR(H1) × `InpTPATRMultiplier` by default, or a fixed points value — same rationale as the averaging distance below). Without this, positions would never close.
6. **Time filter:** new entries and averaging adds only happen inside an allowed day-of-week + intraday time window (broker/server time). The default window (08:00–21:00) targets the London/NY session overlap, where gold typically trends and trades better than the quieter Asian session — adjust to your broker's server time zone. On Fridays the window closes earlier (default 14:00) to reduce weekend-gap exposure, regardless of the general end time. Existing baskets can still be closed by the take-profit rule at any time, even outside the window.
7. **News filter:** new entries and averaging adds also pause from `InpNewsMinutesBefore` before to `InpNewsMinutesAfter` after any calendar event at or above `InpNewsMinImportance` (default High) for the symbol's base or profit currency (e.g. XAU and USD for XAUUSD) — this strategy has no per-order stop loss, so it's specifically meant to avoid opening new grid levels right into a news-driven spike/gap. It only blocks new orders; existing baskets can still hit their take-profit or max-floating-loss exit during a blackout. Uses the terminal's built-in Economic Calendar, so it needs calendar data to be available (works normally in live/demo; in the Strategy Tester it depends on calendar history being downloaded for the tested period — verify it's actually filtering before relying on it in a backtest).
8. **Daily profit target:** at the start of each new day (broker/server time), the account balance is recorded as that day's baseline. Once today's profit (current equity − that baseline) reaches `InpDailyTargetPercent` of the baseline (default 20%), the EA stops opening new entries and averaging orders for the rest of the day, and — if `InpCloseAllOnDailyTarget` is on (default) — immediately closes every open BUY/SELL basket to lock the gain in. It resumes normally at the next day rollover. This checks the whole account's equity/balance, not just this EA's own positions, so it only behaves as a pure "this EA's daily target" if nothing else trades the account.
9. **Max floating loss (hard risk cap):** checked every tick, independently of the time filter and daily target. If one basket's own floating loss (sum of that basket's position profit + swap) reaches `InpMaxFloatingLossPercent` of the account balance (default 10%), that basket alone is force-closed — the other side is untouched. This is the only stop loss in the strategy; without it a basket can average all the way to `InpMaxAveragingOrders` with no exit on the loss side. Note: closing a basket this way doesn't block it from reopening — if the H1 trend and entry bias still agree right after the close, a fresh basket can start immediately on the same side.
10. **Global take-profit (close all):** checked every tick, ahead of everything else. When `InpUseGlobalTP` is on (default), the combined floating profit of BUY basket + SELL basket together reaching `InpGlobalTPMoney` (default $200, account currency — not a percentage) immediately closes **every** open position from both baskets. This is separate from, and independent of, the per-basket take-profit in point 5: it looks at the net dollar result across everything this EA has open, so it can close out a losing basket together with a winning one the moment the combined total hits the target, rather than waiting for each basket to reach its own price-based target on its own.
11. **Trailing stop (per position):** independent of the basket-level exits above, each individual position gets its own broker-side trailing stop. Once a position is more than `InpTrailingStopPoints` (default 300) in profit, its SL trails behind the current price at that same distance; the SL is only moved again once price has improved by at least `InpTrailingStepPoints` (default 200) since the last move. Since positions in a basket can have different open prices (from averaging), each one trails independently — a position can hit its trailing stop and close on its own before the whole basket reaches its take-profit target, which changes that basket's remaining average price.
12. **Lot compounding (optional, off by default):** when `InpUseCompounding` is on, a brand-new basket's lot size scales with the account balance at the start of the day instead of always using `InpLots`. Every `InpCompoundingBalanceStep` of balance adds one `InpCompoundingLotIncrement` to the lot, floored at `InpLots` and capped at `InpMaxLots` — because it's computed from balance (not a locked-in high-water mark), the lot scales back down again during a drawdown, not just up during a winning streak. The lot is fixed for a basket at the moment it opens and every subsequent averaging order in that basket reuses that same lot (via the existing positions' own volume), so compounding never changes the lot size in the middle of an open basket.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpADXPeriodH1` | 14 | ADX period on H1 |
| `InpADXTrendLevel` | 25.0 | ADX level that confirms a trend |
| `InpMinDISpreadH1` | 5.0 | Min. DI+/DI- separation on H1 for a trend to count (rejects a razor-thin DI cross) |
| `InpEntryTimeframe` | M15 | Entry timeframe: M1, M5, or M15 |
| `InpADXPeriodEntry` | 14 | ADX period on the entry timeframe |
| `InpADXMinLevelEntry` | 20.0 | Min. ADX on the entry timeframe for a signal to count (filters choppy/no-momentum bars) |
| `InpMinDISpreadEntry` | 5.0 | Min. DI+/DI- separation on the entry timeframe for a signal to count |
| `InpLots` | 0.01 | Base/minimum lot size (also the fixed lot when compounding is off) |
| `InpUseCompounding` | false | Scale a new basket's lot with account balance instead of always using `InpLots` |
| `InpCompoundingBalanceStep` | 100.0 | Balance increment that adds one `InpCompoundingLotIncrement` — must be tuned to your account size |
| `InpCompoundingLotIncrement` | 0.01 | Lot added per `InpCompoundingBalanceStep` of balance |
| `InpMaxLots` | 1.0 | Maximum lot size cap (applies with or without compounding) |
| `InpAveragingMode` | ATR | `Fixed points` = constant distance; `ATR` = distance scales with H1 volatility |
| `InpAveragingPoints` | 500 | Distance between averaging orders, in raw broker points (used only when mode = Fixed points) |
| `InpATRPeriod` | 14 | ATR period on H1 (used only when mode = ATR) |
| `InpATRMultiplier` | 3.0 | Averaging distance = ATR(H1) × this multiplier (used only when mode = ATR) |
| `InpMaxAveragingOrders` | 5 | Max open orders per basket |
| `InpTakeProfitMode` | ATR | `Fixed points` = constant TP distance; `ATR` = TP distance scales with H1 volatility |
| `InpTakeProfitPoints` | 200 | Basket close distance from average price, in raw broker points (used only when mode = Fixed points) |
| `InpTPATRMultiplier` | 1.5 | Basket TP distance = ATR(H1) × this multiplier (used only when mode = ATR) |
| `InpMaxSpreadPoints` | 50 | Skip new/averaging entries if spread exceeds this |
| `InpMagicNumber` | 202609 | Magic number used to identify/manage this EA's orders |
| `InpSlippagePoints` | 10 | Max allowed slippage on order execution |
| `InpUseTimeFilter` | true | Enable the trading-hours filter |
| `InpStartHour` / `InpStartMinute` | 8 / 0 | Start of allowed trading window (broker/server time) — default targets the London/NY overlap |
| `InpEndHour` / `InpEndMinute` | 21 / 0 | End of allowed trading window (broker/server time); if start > end, the window wraps past midnight |
| `InpTradeMonday` … `InpTradeFriday` | true | Allow trading on that weekday |
| `InpTradeSaturday` / `InpTradeSunday` | false | Allow trading on that weekend day |
| `InpUseFridayEarlyClose` | true | On Friday, use `InpFridayEndHour`/`InpFridayEndMinute` instead of `InpEndHour`/`InpEndMinute` as the cutoff for new entries |
| `InpFridayEndHour` / `InpFridayEndMinute` | 14 / 0 | Friday-only cutoff time for new entries/averaging (broker/server time) |
| `InpUseNewsFilter` | true | Pause new entries/averaging around high-impact calendar events |
| `InpNewsMinutesBefore` / `InpNewsMinutesAfter` | 30 / 30 | Blackout window around a qualifying event |
| `InpNewsMinImportance` | High | Minimum calendar event importance treated as "news" (Low / Moderate / High) |
| `InpUseDailyTarget` | true | Stop opening new trades once today's profit target is hit |
| `InpDailyTargetPercent` | 20.0 | Daily profit target, as % of the account balance at the start of the day |
| `InpCloseAllOnDailyTarget` | true | Also close every open position (both baskets) once the daily target is hit, instead of just pausing new entries |
| `InpUseMaxFloatingLoss` | true | Force-close a basket once its own floating loss gets too big |
| `InpMaxFloatingLossPercent` | 10.0 | Max floating loss per basket, as % of account balance |
| `InpUseGlobalTP` | true | Close every open position (both baskets combined) once total floating profit hits the target |
| `InpGlobalTPMoney` | 200.0 | Total floating profit target across both baskets, in account currency (a fixed $ amount, not a %) |
| `InpUseTrailingStop` | true | Enable the per-position trailing stop |
| `InpTrailingStopPoints` | 300 | Trailing distance behind price, in points, once a position is that far in profit |
| `InpTrailingStepPoints` | 200 | Minimum additional profit (points) before the trailing SL is moved again |

## Why points/ATR instead of "pips"

Earlier versions measured averaging/take-profit distance in "pips", converted with the standard FX rule (1 pip = 10 points on 3/5-digit symbols). That rule silently breaks on non-forex symbols quoted with 2 decimals, like XAUUSD: `500 pips` was actually only `500 points = $5`, which gold can move through in minutes — baskets filled to the 10-order cap almost immediately with deep floating losses.

The EA now works directly in **broker points** (`InpAveragingPoints`, `InpTakeProfitPoints`) with no pip conversion, plus an **ATR-based mode** for both the averaging distance (`InpAveragingMode = ATR`, default `InpATRMultiplier = 3.0`) and the take-profit distance (`InpTakeProfitMode = ATR`, default `InpTPATRMultiplier = 1.5`) — both the default now — which adapt automatically to each symbol's real volatility instead of relying on a fixed number that only made sense for one type of instrument. The TP multiplier is deliberately smaller than the averaging multiplier so a basket tends to reach take-profit before it needs another averaging order. Check the "Averaging distance" / "TP distance" lines in the on-chart comment to see the live distances being used, and tune the multipliers (or switch either to `Fixed points` with a value you've sized for the instrument) to taste.

## About lot compounding

Compounding is **off by default** because it multiplies risk with an already-multiplying grid: each basket can hold up to `InpMaxAveragingOrders` positions, and BUY/SELL can both be open at once, so a bigger base lot means a bigger position at every one of those levels, not just a bigger single trade. If you turn it on:

- It's balance-based and symmetric — the lot goes back down as balance drops, not just up as it grows — specifically so a losing streak doesn't get stuck trading a large lot sized from a prior high balance.
- `InpCompoundingBalanceStep` and `InpCompoundingLotIncrement` have no safe universal default; they must be sized to *your* account balance and risk tolerance (e.g. for a $1,000 account you probably want a much bigger step than the $100 default, or a much smaller increment).
- Always set `InpMaxLots` to a value you're genuinely willing to hold up to `InpMaxAveragingOrders` times over, on both sides at once.
- Consider tightening `InpMaxFloatingLossPercent` and/or lowering `InpMaxAveragingOrders` when compounding is on, since the nominal size of the worst case grows with the account.

## Risk note

This is a martingale-style averaging strategy: with `InpMaxAveragingOrders = 5`, a single basket can still accumulate meaningful exposure before it stops adding orders (raise this only after you've validated results, since it directly multiplies worst-case exposure). `InpMaxFloatingLossPercent` (default 10% of balance per basket) is the hard stop that caps how deep that loss can go — size `InpLots`, the averaging distance, and this percentage together for your account balance. Because BUY and SELL baskets are independent, both sides can be open (hedged) at once on trend flips, so worst-case combined floating loss across both baskets is up to double the per-basket limit (roughly 20% of balance with the defaults) before both would be stopped out.
