//+------------------------------------------------------------------+
//|                                       Gold_Single_Entry_EA.mq5  |
//|  XAUUSD single-entry pullback EA: H1 trend filter + M15 RSI      |
//|  pullback entry, one position at a time, fixed SL/TP (ATR),      |
//|  break-even, no averaging and no martingale.                     |
//+------------------------------------------------------------------+
#property copyright "Gold Single Entry EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- H1 trend filter
input group "=== Trend Filter (H1) ==="
input int      InpEMAFastH1          = 50;      // Fast EMA period on H1
input int      InpEMASlowH1          = 200;     // Slow EMA period on H1
input int      InpADXPeriodH1        = 14;      // ADX period on H1
input double   InpADXMinH1           = 15.0;    // Min. ADX on H1 to accept a trend (0 = off)
input bool     InpUseH4Filter        = true;    // Also require the last H4 close on the trend side of the H4 EMA
input int      InpEMAH4              = 50;      // H4 EMA period for that confirmation

//--- Entry (pullback)
input group "=== Entry (Pullback) ==="
input bool     InpUsePullback        = true;    // Strategy 1: trend pullback (RSI) entries
input ENUM_TIMEFRAMES InpEntryTimeframe = PERIOD_M15; // Entry timeframe
input int      InpRSIPeriod          = 14;      // RSI period on entry TF
input double   InpRSIBuyLevel        = 45.0;    // BUY: RSI must have dipped to/below this during the pullback
input double   InpRSISellLevel       = 55.0;    // SELL: RSI must have risen to/above this during the pullback
input double   InpRSITriggerLevel    = 50.0;    // Entry fires when RSI crosses back over this level (BUY: up, SELL: down)
input int      InpPullbackBars       = 12;      // How many recent closed bars the pullback may lie within
input double   InpMaxTriggerBarATR   = 1.5;     // Skip if the trigger bar's range > ATR * this (news spike / chasing); 0 = off

//--- Strategy 2: Asian range breakout at London open
input group "=== Strategy 2: Asian Range Breakout ==="
input bool     InpUseBreakout        = true;    // Trade a breakout of the Asian-session range
input int      InpAsiaStartHour      = 1;       // Asian range start hour (server time)
input int      InpAsiaEndHour        = 9;       // Asian range end hour = breakout window start (server time)
input int      InpBreakoutEndHour    = 13;      // No new breakout entries from this hour on (server time)
input double   InpBreakoutBuffer     = 0.50;    // Bar must close this far ($) beyond the range edge
input double   InpMinRangeATR        = 1.0;     // Skip if the range is narrower than ATR(entry TF) * this
input double   InpMaxRangeATR        = 6.0;     // Skip if the range is wider than ATR(entry TF) * this
input bool     InpBreakoutTrendFilter = true;   // Only break out in the H1 (+H4) trend direction
input double   InpBreakoutSLBuffer   = 0.50;    // SL = range midpoint, plus this buffer ($)

//--- SL / TP
input group "=== Stop Loss / Take Profit ==="
input int      InpATRPeriod          = 14;      // ATR period on entry TF
input double   InpSLATRMult          = 2.0;     // SL distance = ATR(entry TF) * this
input double   InpTPATRMult          = 1.0;     // TP distance = ATR(entry TF) * this (TP1 when partial close is on)
input double   InpMinSLPrice         = 3.0;     // Lower clamp for SL distance, in price units ($ for XAUUSD)
input double   InpMaxSLPrice         = 40.0;    // Skip the trade if the ATR SL is bigger than this, in price units ($)

//--- Partial close (TP1 / TP2)
input group "=== Partial Close (TP1 / TP2) ==="
input bool     InpUsePartialClose    = true;    // Close part of the position at TP1, let the rest run to TP2
input double   InpPartialPercent     = 50.0;    // % of the volume closed at TP1
input double   InpTP2ATRMult         = 2.5;     // TP2 (broker TP of the runner) = ATR(entry TF) * this

//--- Break-even
input group "=== Break-even ==="
input bool     InpUseBreakEven       = true;    // Move SL to entry once the trade is far enough in profit
input double   InpBETriggerPercent   = 60.0;    // Trigger: price has covered this % of the TP distance
input double   InpBELockPrice        = 0.30;    // SL is placed this far past entry, in price units ($) - covers spread/commission

//--- Dynamic trailing stop (ATR based)
input group "=== Dynamic Trailing Stop (ATR) ==="
input bool     InpUseTrailing        = true;    // Trail the SL behind price once the trade is in profit
input double   InpTrailStartATR      = 0.6;     // Start trailing once profit >= ATR(entry TF) * this
input double   InpTrailATRMult       = 0.5;     // Trailing distance behind price = current ATR(entry TF) * this
input double   InpTrailStepPrice     = 0.20;    // Only move the SL when it improves by at least this much ($)
input bool     InpTrailRemoveTP      = false;   // Remove the TP once trailing starts and let the trail take the exit

//--- Money management
input group "=== Money Management ==="
input bool     InpUseRiskPercent     = true;    // Size the lot from InpRiskPercent and the SL distance
input double   InpRiskPercent        = 1.0;     // Risk per trade, % of balance (when InpUseRiskPercent = true)
input double   InpFixedLots          = 0.01;    // Fixed lot (when InpUseRiskPercent = false)
input double   InpMaxLots            = 1.0;     // Lot cap

//--- Daily limits
input group "=== Daily Limits ==="
input int      InpMaxTradesPerDay    = 3;       // Max entries per day (0 = unlimited)
input int      InpMaxLossesPerDay    = 1;       // Stop for the day after this many losing trades (0 = off)
input double   InpMaxDailyLossPercent = 3.0;    // Stop for the day once today's closed loss reaches this % of day-start balance (0 = off)

//--- Filters / identification
input group "=== Filters ==="
input double   InpMaxSpreadPrice     = 0.60;    // Max allowed spread, in price units ($ for XAUUSD)
input bool     InpDebugLog           = true;    // Print why no trade was opened, once per entry-TF bar
input int      InpMagicNumber        = 202611;  // Magic number
input int      InpSlippagePoints     = 50;      // Max deviation for orders (points)

//--- Strategy Tester optimisation (only used by "Custom max" optimisation)
input group "=== Optimisation (Strategy Tester) ==="
input double   InpOptMinWinRate      = 80.0;    // Pass must reach this win rate (%) to score
input int      InpOptMinTrades       = 30;      // Pass must have at least this many trades to score

//--- Time filter
input group "=== Time Filter (broker/server time) ==="
input bool     InpUseTimeFilter      = true;    // Enable trading-hours filter
input int      InpStartHour          = 9;       // Start hour (0-23)
input int      InpStartMinute        = 0;       // Start minute (0-59)
input int      InpEndHour            = 20;      // End hour (0-23)
input int      InpEndMinute          = 0;       // End minute (0-59)
input bool     InpTradeMonday        = true;
input bool     InpTradeTuesday       = true;
input bool     InpTradeWednesday     = true;
input bool     InpTradeThursday      = true;
input bool     InpTradeFriday        = true;
input bool     InpUseFridayEarlyClose = true;   // On Friday, stop new entries earlier
input int      InpFridayEndHour      = 14;      // Friday cutoff hour (0-23)
input int      InpFridayEndMinute    = 0;       // Friday cutoff minute (0-59)

//--- News filter
input group "=== News Filter ==="
input bool     InpUseNewsFilter      = true;    // No new entry around high-impact news
input int      InpNewsMinutesBefore  = 60;      // Minutes before a qualifying event to start the blackout
input int      InpNewsMinutesAfter   = 60;      // Minutes after a qualifying event to end the blackout
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum event importance treated as "news"

CTrade         trade;
int            hEMAFastH1 = INVALID_HANDLE;
int            hEMASlowH1 = INVALID_HANDLE;
int            hADX_H1    = INVALID_HANDLE;
int            hRSI       = INVALID_HANDLE;
int            hATR       = INVALID_HANDLE;
int            hEMAH4     = INVALID_HANDLE;
datetime       g_lastEntryBarTime = 0;
datetime       g_currentDayStart  = 0;
double         g_dayStartBalance  = 0.0;
string         g_lastStatus       = "";
string         g_lastSkipped      = "";   // last signal a filter blocked, for the chart comment
datetime       g_lastLogBarTime   = 0;
bool           g_statsDirty       = true;   // re-read deal history on the next tick
int            g_todayEntries = 0, g_todayLosses = 0;
double         g_todayNet     = 0.0;
int            g_allWins      = 0, g_allLosses   = 0;
double         g_allNet       = 0.0;

enum ENUM_TREND
  {
   TREND_NONE = 0,
   TREND_BUY  = 1,
   TREND_SELL = -1
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   // Use a filling mode the symbol actually supports; CTrade's FOK default
   // gets every order rejected (retcode 10030) on brokers that only allow IOC.
   trade.SetTypeFillingBySymbol(_Symbol);

   hEMAFastH1 = iMA(_Symbol, PERIOD_H1, InpEMAFastH1, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlowH1 = iMA(_Symbol, PERIOD_H1, InpEMASlowH1, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H1    = iADX(_Symbol, PERIOD_H1, InpADXPeriodH1);
   hRSI       = iRSI(_Symbol, InpEntryTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hATR       = iATR(_Symbol, InpEntryTimeframe, InpATRPeriod);
   hEMAH4     = iMA(_Symbol, PERIOD_H4, InpEMAH4, 0, MODE_EMA, PRICE_CLOSE);

   if(hEMAFastH1 == INVALID_HANDLE || hEMASlowH1 == INVALID_HANDLE || hADX_H1 == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE || hEMAH4 == INVALID_HANDLE)
     {
      Print("Failed to create indicator handle(s).");
      return(INIT_FAILED);
     }

   if(InpTPATRMult >= InpSLATRMult)
      Print("Note: TP >= SL. Win rate will be lower than with the default TP < SL setup.");
   if(InpUsePartialClose && InpTP2ATRMult <= InpTPATRMult)
      Print("Note: InpTP2ATRMult <= InpTPATRMult, so the runner has no room beyond TP1.");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEMAFastH1 != INVALID_HANDLE) IndicatorRelease(hEMAFastH1);
   if(hEMASlowH1 != INVALID_HANDLE) IndicatorRelease(hEMASlowH1);
   if(hADX_H1    != INVALID_HANDLE) IndicatorRelease(hADX_H1);
   if(hRSI       != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR       != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMAH4     != INVALID_HANDLE) IndicatorRelease(hEMAH4);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Spread is compared in price units, not points: XAUUSD is quoted   |
//| with 2 digits by some brokers and 3 by others, so a points limit  |
//| sized for one silently blocks every trade on the other.           |
double CurrentSpread()
  {
   return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
  }

bool SpreadOK()
  {
   return CurrentSpread() <= InpMaxSpreadPrice;
  }

//+------------------------------------------------------------------+
//| Day-of-week + intraday time window filter (broker/server time)   |
//+------------------------------------------------------------------+
bool IsWithinTradingTime()
  {
   if(!InpUseTimeFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool dayAllowed;
   switch(dt.day_of_week)
     {
      case 1: dayAllowed = InpTradeMonday;    break;
      case 2: dayAllowed = InpTradeTuesday;   break;
      case 3: dayAllowed = InpTradeWednesday; break;
      case 4: dayAllowed = InpTradeThursday;  break;
      case 5: dayAllowed = InpTradeFriday;    break;
      default: dayAllowed = false;            break;
     }
   if(!dayAllowed)
      return false;

   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = InpStartHour * 60 + InpStartMinute;
   int endMinutes   = InpEndHour * 60 + InpEndMinute;

   if(dt.day_of_week == 5 && InpUseFridayEarlyClose)
      endMinutes = InpFridayEndHour * 60 + InpFridayEndMinute;

   if(startMinutes <= endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= endMinutes);

   // window wraps past midnight (e.g. 22:00 -> 05:00)
   return (nowMinutes >= startMinutes || nowMinutes <= endMinutes);
  }

//+------------------------------------------------------------------+
//| True while "now" is within InpNewsMinutesBefore/After of a        |
//| qualifying calendar event for the symbol's base or profit         |
//| currency. Cached for a minute.                                    |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
  {
   if(!InpUseNewsFilter)
      return false;

   static datetime lastCheck    = 0;
   static bool     cachedResult = false;

   datetime now = TimeCurrent();
   if(lastCheck != 0 && now - lastCheck < 60)
      return cachedResult;
   lastCheck = now;

   datetime queryFrom = now - InpNewsMinutesAfter  * 60;
   datetime queryTo   = now + InpNewsMinutesBefore * 60;

   string currencies[2];
   currencies[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   currencies[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   bool blackout = false;
   for(int c = 0; c < 2 && !blackout; c++)
     {
      if(currencies[c] == "" || (c == 1 && currencies[1] == currencies[0]))
         continue;

      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, queryFrom, queryTo, NULL, currencies[c]))
         continue;

      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event))
            continue;
         if(event.importance >= InpNewsMinImportance)
           {
            blackout = true;
            break;
           }
        }
     }

   cachedResult = blackout;
   return blackout;
  }

//+------------------------------------------------------------------+
//| H1 trend: EMA fast above slow and last H1 close above the slow    |
//| EMA (plus optional min. ADX) => BUY; mirror image => SELL.        |
//| Deliberately NOT stricter than that: a stricter version (close    |
//| beyond the *fast* EMA + DI agreement) switched itself off during  |
//| exactly the pullbacks this EA wants to trade, because a pullback  |
//| pushes H1 back toward its fast EMA and flips DI for a few bars.   |
//+------------------------------------------------------------------+
ENUM_TREND GetH1Trend()
  {
   double emaFast[], emaSlow[], adx[];
   if(CopyBuffer(hEMAFastH1, 0, 1, 1, emaFast) <= 0)   return TREND_NONE;
   if(CopyBuffer(hEMASlowH1, 0, 1, 1, emaSlow) <= 0)   return TREND_NONE;
   if(CopyBuffer(hADX_H1, MAIN_LINE, 1, 1, adx) <= 0)  return TREND_NONE;

   double closeH1 = iClose(_Symbol, PERIOD_H1, 1);
   if(closeH1 <= 0.0 || adx[0] < InpADXMinH1)
      return TREND_NONE;

   ENUM_TREND trend = TREND_NONE;
   if(emaFast[0] > emaSlow[0] && closeH1 > emaSlow[0])
      trend = TREND_BUY;
   else if(emaFast[0] < emaSlow[0] && closeH1 < emaSlow[0])
      trend = TREND_SELL;

   // Higher-timeframe confirmation: only trade H1 pullbacks that also run
   // with the H4 picture, skipping counter-moves inside a bigger H4 trend.
   if(trend != TREND_NONE && InpUseH4Filter)
     {
      double emaH4[];
      double closeH4 = iClose(_Symbol, PERIOD_H4, 1);
      if(CopyBuffer(hEMAH4, 0, 1, 1, emaH4) <= 0 || closeH4 <= 0.0)
         return TREND_NONE;
      if(trend == TREND_BUY && closeH4 <= emaH4[0])
         return TREND_NONE;
      if(trend == TREND_SELL && closeH4 >= emaH4[0])
         return TREND_NONE;
     }
   return trend;
  }

//+------------------------------------------------------------------+
//| A trigger bar much bigger than ATR is usually a news spike or a   |
//| move that already happened; entering after it means chasing, and  |
//| the ATR-sized TP/SL no longer fit the bar that set them up.       |
//+------------------------------------------------------------------+
bool TriggerBarTooBig(string &reason)
  {
   if(InpMaxTriggerBarATR <= 0.0)
      return false;
   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) <= 0 || atr[0] <= 0.0)
      return false;
   double range = iHigh(_Symbol, InpEntryTimeframe, 1) - iLow(_Symbol, InpEntryTimeframe, 1);
   if(range <= atr[0] * InpMaxTriggerBarATR)
      return false;
   reason = StringFormat("trigger bar too big (%.2f > ATR %.2f x %.1f)", range, atr[0], InpMaxTriggerBarATR);
   return true;
  }

//+------------------------------------------------------------------+
//| Pullback trigger on the last closed entry-TF bar (bar 1):         |
//| BUY  - within the last InpPullbackBars bars RSI dipped to/below   |
//|        InpRSIBuyLevel (the pullback), and on bar 1 RSI crosses    |
//|        back up over InpRSITriggerLevel (the trend resumes) on a   |
//|        bullish bar. Firing on the cross means one signal per      |
//|        pullback, not one per bar.                                 |
//| SELL - mirror image.                                              |
//| An earlier version also demanded that the very first turn bar     |
//| close beyond the entry-TF EMA; after a real pullback price is on  |
//| the wrong side of that EMA, so the two almost never coincided.    |
//| 'reason' explains a rejection, for the debug log.                 |
//+------------------------------------------------------------------+
ENUM_TREND GetPullbackSignal(ENUM_TREND trend, string &reason)
  {
   reason = "";
   if(trend == TREND_NONE)
     { reason = "no H1 trend"; return TREND_NONE; }

   int bars = MathMax(InpPullbackBars, 2) + 1;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRSI, 0, 1, bars, rsi) < bars)  { reason = "RSI not ready"; return TREND_NONE; }

   double open1  = iOpen(_Symbol, InpEntryTimeframe, 1);
   double close1 = iClose(_Symbol, InpEntryTimeframe, 1);
   if(open1 <= 0.0 || close1 <= 0.0)
     { reason = "no bar data"; return TREND_NONE; }

   // rsi[0] = bar 1 (last closed), rsi[1] = bar 2, ...; the pullback is looked for in bars 2..N+1
   double rsiMin = rsi[1], rsiMax = rsi[1];
   for(int i = 2; i < bars; i++)
     {
      rsiMin = MathMin(rsiMin, rsi[i]);
      rsiMax = MathMax(rsiMax, rsi[i]);
     }

   if(trend == TREND_BUY)
     {
      if(rsiMin > InpRSIBuyLevel)
        { reason = StringFormat("BUY: waiting for pullback (min RSI %.1f > %.1f)", rsiMin, InpRSIBuyLevel); return TREND_NONE; }
      if(!(rsi[0] > InpRSITriggerLevel && rsi[1] <= InpRSITriggerLevel))
        { reason = StringFormat("BUY: pullback seen, waiting for RSI to cross up %.0f (now %.1f)", InpRSITriggerLevel, rsi[0]); return TREND_NONE; }
      if(close1 <= open1)
        { reason = "BUY: trigger bar not bullish"; return TREND_NONE; }
      if(TriggerBarTooBig(reason))
         return TREND_NONE;
      return TREND_BUY;
     }

   if(rsiMax < InpRSISellLevel)
     { reason = StringFormat("SELL: waiting for pullback (max RSI %.1f < %.1f)", rsiMax, InpRSISellLevel); return TREND_NONE; }
   if(!(rsi[0] < InpRSITriggerLevel && rsi[1] >= InpRSITriggerLevel))
     { reason = StringFormat("SELL: pullback seen, waiting for RSI to cross down %.0f (now %.1f)", InpRSITriggerLevel, rsi[0]); return TREND_NONE; }
   if(close1 >= open1)
     { reason = "SELL: trigger bar not bearish"; return TREND_NONE; }
   if(TriggerBarTooBig(reason))
      return TREND_NONE;
   return TREND_SELL;
  }

//+------------------------------------------------------------------+
//| High/low of today's Asian session on the entry timeframe, from    |
//| InpAsiaStartHour to InpAsiaEndHour (server time). Only available  |
//| once that window has closed.                                      |
//+------------------------------------------------------------------+
bool GetAsianRange(double &hi, double &lo)
  {
   datetime day  = iTime(_Symbol, PERIOD_D1, 0);
   if(day == 0)
      return false;
   datetime from = day + InpAsiaStartHour * 3600;
   datetime to   = day + InpAsiaEndHour * 3600;
   if(TimeCurrent() < to || to <= from)
      return false;

   MqlRates r[];
   int n = CopyRates(_Symbol, InpEntryTimeframe, from, to - 1, r);
   if(n < 4)
      return false;
   hi = -DBL_MAX;
   lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   return hi > lo;
  }

//+------------------------------------------------------------------+
//| One breakout trade per day: true if a breakout position (order    |
//| comment contains "BO") was already opened today.                  |
//+------------------------------------------------------------------+
bool BreakoutTradedToday()
  {
   if(!HistorySelect(iTime(_Symbol, PERIOD_D1, 0), TimeCurrent() + 60))
      return false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagicNumber &&
         HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN &&
         StringFind(HistoryDealGetString(deal, DEAL_COMMENT), "BO") >= 0)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Asian range breakout on the last closed entry-TF bar (bar 1):     |
//| BUY  - bar 1 closes above range high + buffer, bar 2 did not (a   |
//|        fresh break), bar 1 is bullish, inside the breakout window |
//|        and (optionally) in the H1/H4 trend direction.             |
//| SELL - mirror image.                                              |
//| slPrice = range midpoint -/+ InpBreakoutSLBuffer: if price falls  |
//| back to the middle of the range, the breakout has failed.         |
//+------------------------------------------------------------------+
ENUM_TREND GetBreakoutSignal(ENUM_TREND trend, string &reason, double &slPrice)
  {
   reason = "";
   slPrice = 0.0;
   if(!InpUseBreakout)
      return TREND_NONE;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpAsiaEndHour || dt.hour >= InpBreakoutEndHour)
     { reason = "BO: outside breakout window"; return TREND_NONE; }
   if(InpBreakoutTrendFilter && trend == TREND_NONE)
     { reason = "BO: no trend"; return TREND_NONE; }

   double hi, lo;
   if(!GetAsianRange(hi, lo))
     { reason = "BO: Asian range not available"; return TREND_NONE; }

   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) <= 0 || atr[0] <= 0.0)
     { reason = "BO: ATR not ready"; return TREND_NONE; }
   double range = hi - lo;
   if(range < atr[0] * InpMinRangeATR)
     { reason = StringFormat("BO: range %.2f too narrow", range); return TREND_NONE; }
   if(range > atr[0] * InpMaxRangeATR)
     { reason = StringFormat("BO: range %.2f too wide", range); return TREND_NONE; }

   double open1  = iOpen(_Symbol, InpEntryTimeframe, 1);
   double close1 = iClose(_Symbol, InpEntryTimeframe, 1);
   double close2 = iClose(_Symbol, InpEntryTimeframe, 2);
   if(open1 <= 0.0 || close1 <= 0.0 || close2 <= 0.0)
     { reason = "BO: no bar data"; return TREND_NONE; }

   double upLevel = hi + InpBreakoutBuffer;
   double dnLevel = lo - InpBreakoutBuffer;
   double mid = (hi + lo) / 2.0;
   ENUM_TREND sig = TREND_NONE;
   if(close1 > upLevel && close2 <= upLevel && close1 > open1 &&
      (!InpBreakoutTrendFilter || trend == TREND_BUY))
     {
      sig = TREND_BUY;
      slPrice = mid - InpBreakoutSLBuffer;
     }
   else if(close1 < dnLevel && close2 >= dnLevel && close1 < open1 &&
           (!InpBreakoutTrendFilter || trend == TREND_SELL))
     {
      sig = TREND_SELL;
      slPrice = mid + InpBreakoutSLBuffer;
     }

   if(sig == TREND_NONE)
     {
      reason = StringFormat("BO: waiting for break of %.2f / %.2f", upLevel, dnLevel);
      return TREND_NONE;
     }
   if(BreakoutTradedToday())
     { reason = "BO: already traded today"; return TREND_NONE; }
   return sig;
  }

//+------------------------------------------------------------------+
//| Both strategies, pullback first. isBreakout/slPrice describe the  |
//| signal that fired; reason combines both "why not" texts.          |
//+------------------------------------------------------------------+
ENUM_TREND GetEntrySignal(ENUM_TREND trend, string &reason, bool &isBreakout, double &slPrice)
  {
   isBreakout = false;
   slPrice = 0.0;
   string r1 = "", r2 = "";
   if(InpUsePullback && trend != TREND_NONE)
     {
      ENUM_TREND sig = GetPullbackSignal(trend, r1);
      if(sig != TREND_NONE)
         return sig;
     }
   if(InpUseBreakout)
     {
      ENUM_TREND sig = GetBreakoutSignal(trend, r2, slPrice);
      if(sig != TREND_NONE)
        {
         isBreakout = true;
         return sig;
        }
     }
   if(!InpUsePullback)
      reason = r2;
   else if(!InpUseBreakout || r2 == "")
      reason = r1 == "" ? "no H1 trend" : r1;
   else
      reason = (r1 == "" ? "PB: no trend" : r1) + " | " + r2;
   return TREND_NONE;
  }

//+------------------------------------------------------------------+
bool IsNewEntryBar()
  {
   datetime t = iTime(_Symbol, InpEntryTimeframe, 0);
   if(t != g_lastEntryBarTime)
     {
      g_lastEntryBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| True while a position with this identifier is still open.         |
//+------------------------------------------------------------------+
bool IsPositionOpen(ulong positionId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && PositionSelectByTicket(ticket) &&
         (ulong)PositionGetInteger(POSITION_IDENTIFIER) == positionId)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Net result of every *fully closed* position of this symbol/magic  |
//| with deals since 'from' (entry commission, partial closes, swap   |
//| all included), plus the number of entries since 'from'. Win rate  |
//| is counted per position, not per deal: with partial close one     |
//| trade produces two exit deals, and counting deals would double-   |
//| count it.                                                         |
//+------------------------------------------------------------------+
void CollectClosedPositions(datetime from, double &nets[], int &entries)
  {
   ArrayResize(nets, 0);
   entries = 0;
   if(!HistorySelect(from, TimeCurrent() + 60))
      return;

   ulong  ids[];
   double sums[];
   bool   hasOut[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;

      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         entries++;

      ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < ArraySize(ids); j++)
         if(ids[j] == pid) { k = j; break; }
      if(k < 0)
        {
         k = ArraySize(ids);
         ArrayResize(ids, k + 1);
         ArrayResize(sums, k + 1);
         ArrayResize(hasOut, k + 1);
         ids[k] = pid;
         sums[k] = 0.0;
         hasOut[k] = false;
        }
      sums[k] += HistoryDealGetDouble(deal, DEAL_PROFIT) +
                 HistoryDealGetDouble(deal, DEAL_SWAP) +
                 HistoryDealGetDouble(deal, DEAL_COMMISSION);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         hasOut[k] = true;
     }

   for(int k = 0; k < ArraySize(ids); k++)
     {
      if(!hasOut[k] || IsPositionOpen(ids[k]))
         continue;
      int n = ArraySize(nets);
      ArrayResize(nets, n + 1);
      nets[n] = sums[k];
     }
  }

//+------------------------------------------------------------------+
//| Today's entries, closed losing positions and closed net P/L.      |
//+------------------------------------------------------------------+
void GetTodayStats(int &entries, int &losses, double &netProfit)
  {
   double nets[];
   CollectClosedPositions(g_currentDayStart, nets, entries);
   losses = 0;
   netProfit = 0.0;
   for(int i = 0; i < ArraySize(nets); i++)
     {
      netProfit += nets[i];
      if(nets[i] < 0.0)
         losses++;
     }
  }

//+------------------------------------------------------------------+
//| All-time win/loss count per closed position (for the on-chart     |
//| comment and OnTester). A position closed at break-even + lock or  |
//| with a profitable partial close counts as a win if its total net  |
//| result is positive.                                               |
//+------------------------------------------------------------------+
void GetAllTimeStats(int &wins, int &losses, double &netProfit)
  {
   double nets[];
   int entries;
   CollectClosedPositions(0, nets, entries);
   wins = 0;
   losses = 0;
   netProfit = 0.0;
   for(int i = 0; i < ArraySize(nets); i++)
     {
      netProfit += nets[i];
      if(nets[i] > 0.0)
         wins++;
      else
         losses++;
     }
  }

//+------------------------------------------------------------------+
void UpdateDayStart()
  {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return;
   if(dayStart != g_currentDayStart)
     {
      g_currentDayStart = dayStart;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_statsDirty = true;
     }
  }

//+------------------------------------------------------------------+
//| True once any daily limit says "no more new trades today".       |
//+------------------------------------------------------------------+
bool DailyLimitReached(string &reason)
  {
   if(InpMaxTradesPerDay > 0 && g_todayEntries >= InpMaxTradesPerDay)
     { reason = "max trades per day"; return true; }
   if(InpMaxLossesPerDay > 0 && g_todayLosses >= InpMaxLossesPerDay)
     { reason = "max losses per day"; return true; }
   if(InpMaxDailyLossPercent > 0.0 && g_dayStartBalance > 0.0 &&
      -g_todayNet >= g_dayStartBalance * InpMaxDailyLossPercent / 100.0)
     { reason = "max daily loss"; return true; }
   return false;
  }

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMin(lots, MathMin(maxLot, InpMaxLots));
   lots = MathMax(lots, minLot);
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Lot sized so that hitting the SL loses InpRiskPercent of balance. |
//+------------------------------------------------------------------+
double CalcLots(ENUM_ORDER_TYPE type, double price, double sl)
  {
   if(!InpUseRiskPercent)
      return NormalizeLots(InpFixedLots);

   double lossPerLot = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, price, sl, lossPerLot) || lossPerLot >= 0.0)
      return NormalizeLots(InpFixedLots);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double lots      = NormalizeLots(riskMoney / MathAbs(lossPerLot));

   // NormalizeLots floors at the broker's minimum lot; on a small account
   // that can mean far more risk than InpRiskPercent - say so in the log.
   double actualRiskPct = balance > 0.0 ? 100.0 * lots * MathAbs(lossPerLot) / balance : 0.0;
   if(actualRiskPct > InpRiskPercent * 1.5)
      PrintFormat("Warning: min lot %.2f risks %.1f%% of balance at this SL (target %.1f%%). Account is small for this SL size.",
                  lots, actualRiskPct, InpRiskPercent);
   return lots;
  }

//+------------------------------------------------------------------+
//| Terminal global variable holding a position's TP1 price. Exists   |
//| only until TP1 has been taken.                                    |
//+------------------------------------------------------------------+
string TP1VarName(ulong positionId)
  {
   return StringFormat("GSE_%d_%I64u_TP1", InpMagicNumber, positionId);
  }

//+------------------------------------------------------------------+
//| Remember TP1 = fill price + signedDist for a new position.        |
//+------------------------------------------------------------------+
void StoreTP1(ulong positionId, double fillPrice, double signedDist, int digits)
  {
   if(positionId == 0)
      return;
   GlobalVariableSet(TP1VarName(positionId), NormalizeDouble(fillPrice + signedDist, digits));
  }

//+------------------------------------------------------------------+
bool TryOpen(ENUM_TREND signal, double slPrice = 0.0, bool isBreakout = false)
  {
   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) <= 0 || atr[0] <= 0.0)
      return false;

   // Breakout trades pass a structural SL price (range midpoint);
   // pullback trades use the ATR-based distance.
   double refPrice = (signal == TREND_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = (slPrice > 0.0) ? MathAbs(refPrice - slPrice) : atr[0] * InpSLATRMult;
   if(slPrice > 0.0 && ((signal == TREND_BUY && slPrice >= refPrice) || (signal == TREND_SELL && slPrice <= refPrice)))
     {
      Print("Skip: breakout SL is on the wrong side of price (price already back in the range).");
      return false;
     }
   double tpDist = atr[0] * InpTPATRMult;
   double tp2Dist = atr[0] * InpTP2ATRMult;
   double minSL  = InpMinSLPrice;
   double maxSL  = InpMaxSLPrice;
   if(slDist > maxSL)
     {
      PrintFormat("Skip: SL %.2f exceeds InpMaxSLPrice %.2f (market too volatile / range too wide).", slDist, maxSL);
      return false;
     }
   if(slDist < minSL)
     {
      // keep the TP:SL ratio when the SL is clamped up (ATR mode only;
      // a structural SL just gets widened to the minimum)
      if(slPrice <= 0.0)
        {
         tpDist  *= minSL / slDist;
         tp2Dist *= minSL / slDist;
        }
      slDist   = minSL;
     }

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(tpDist <= stopsLevel || slDist <= stopsLevel)
     {
      PrintFormat("Skip: TP %.2f / SL %.2f inside broker stops level %.2f.", tpDist, slDist, stopsLevel);
      return false;
     }

   // With partial close the broker TP is TP2 (for the runner); TP1 is
   // handled by the EA and remembered in a terminal global variable so it
   // survives an EA/terminal restart.
   bool partial = InpUsePartialClose && tp2Dist > tpDist;
   double brokerTPDist = partial ? tp2Dist : tpDist;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(signal == TREND_BUY)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = NormalizeDouble(ask + brokerTPDist, digits);
      double lots = CalcLots(ORDER_TYPE_BUY, ask, sl);
      if(trade.Buy(lots, _Symbol, ask, sl, tp, isBreakout ? "GSE BO BUY" : "GSE PB BUY"))
        {
         if(partial)
            StoreTP1(trade.ResultOrder(), trade.ResultPrice() > 0.0 ? trade.ResultPrice() : ask, tpDist, digits);
         return true;
        }
      PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else if(signal == TREND_SELL)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = NormalizeDouble(bid - brokerTPDist, digits);
      double lots = CalcLots(ORDER_TYPE_SELL, bid, sl);
      if(trade.Sell(lots, _Symbol, bid, sl, tp, isBreakout ? "GSE BO SELL" : "GSE PB SELL"))
        {
         if(partial)
            StoreTP1(trade.ResultOrder(), trade.ResultPrice() > 0.0 ? trade.ResultPrice() : bid, -tpDist, digits);
         return true;
        }
      PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Partial close at TP1: close InpPartialPercent of the volume, move |
//| the runner's SL to break-even + lock, and let it run to TP2 (with |
//| the trailing stop). If the volume is too small to split (e.g.     |
//| 0.01 lot), the whole position is closed at TP1 instead, so the    |
//| trade still behaves like the plain TP1 setup.                     |
//+------------------------------------------------------------------+
void ManagePartialClose()
  {
   if(!InpUsePartialClose)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      stepLot = 0.01;
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      string name = TP1VarName((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      if(!GlobalVariableCheck(name))
         continue;
      double tp1 = GlobalVariableGet(name);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(isBuy ? price < tp1 : price > tp1)
         continue;

      double volume    = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp        = PositionGetDouble(POSITION_TP);
      double closeVol  = MathFloor(volume * InpPartialPercent / 100.0 / stepLot) * stepLot;
      closeVol = NormalizeDouble(closeVol, 2);

      if(closeVol < minLot || volume - closeVol < minLot - 1e-8)
        {
         // Can't split this volume: take the whole trade at TP1.
         if(trade.PositionClose(ticket))
            GlobalVariableDel(name);
         continue;
        }

      if(!trade.PositionClosePartial(ticket, closeVol))
        {
         PrintFormat("Partial close failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
         continue;
        }
      GlobalVariableDel(name);

      // Protect the runner: SL to break-even + lock (never loosen it).
      if(!PositionSelectByTicket(ticket))
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      double beSL = NormalizeDouble(isBuy ? openPrice + InpBELockPrice : openPrice - InpBELockPrice, digits);
      bool better = isBuy ? (sl < beSL || sl == 0.0) : (sl > beSL || sl == 0.0);
      bool legal  = isBuy ? (price - beSL > stopsLevel) : (beSL - price > stopsLevel);
      if(better && legal)
         trade.PositionModify(ticket, beSL, tp);
     }
  }

//+------------------------------------------------------------------+
//| Remove TP1 variables whose position no longer exists (closed by   |
//| SL/TP before reaching TP1).                                       |
//+------------------------------------------------------------------+
void CleanupTP1Vars()
  {
   string prefix = StringFormat("GSE_%d_", InpMagicNumber);
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0 || StringFind(name, "_TP1") < 0)
         continue;
      string idStr = StringSubstr(name, StringLen(prefix), StringLen(name) - StringLen(prefix) - 4);
      if(!IsPositionOpen((ulong)StringToInteger(idStr)))
         GlobalVariableDel(name);
     }
  }

//+------------------------------------------------------------------+
//| Move SL to entry + InpBELockPrice once price has covered          |
//| InpBETriggerPercent of the way to TP. Turns a lot of would-be     |
//| losers (trade goes our way, then reverses) into small wins.       |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpUseBreakEven)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      // While TP1 is still pending, break-even is measured against TP1
      // (the broker TP is then the far-away TP2).
      string tp1Name = TP1VarName((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      double target = GlobalVariableCheck(tp1Name) ? GlobalVariableGet(tp1Name) : tp;
      if(target <= 0.0)
         continue;

      double tpDist = MathAbs(target - openPrice);
      double trigger = tpDist * InpBETriggerPercent / 100.0;
      double lock = InpBELockPrice;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(openPrice + lock, digits);
         if(bid - openPrice >= trigger && (sl < newSL || sl == 0.0) && bid - newSL > stopsLevel)
            trade.PositionModify(ticket, newSL, tp);
        }
      else
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(openPrice - lock, digits);
         if(openPrice - ask >= trigger && (sl > newSL || sl == 0.0) && newSL - ask > stopsLevel)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Deal history only changes on a trade event (or a new day), so it  |
//| is re-read then instead of on every tick.                         |
//+------------------------------------------------------------------+
//| Dynamic trailing stop. The distance is the *current* ATR of the   |
//| entry timeframe times InpTrailATRMult, so it widens when gold     |
//| gets volatile (fewer premature stop-outs) and tightens when it    |
//| calms down (locks in more). It starts once profit reaches         |
//| ATR * InpTrailStartATR, only ever moves the SL in the trade's     |
//| favour, and never places it worse than break-even + lock, so a    |
//| trailed exit is always a (small or large) win.                    |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(!InpUseTrailing)
      return;

   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) <= 0 || atr[0] <= 0.0)
      return;

   double startDist = atr[0] * InpTrailStartATR;
   double trailDist = atr[0] * InpTrailATRMult;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   trailDist = MathMax(trailDist, stopsLevel + _Point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double newTP = InpTrailRemoveTP ? 0.0 : tp;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice < startDist)
            continue;
         double newSL = NormalizeDouble(bid - trailDist, digits);
         newSL = MathMax(newSL, NormalizeDouble(openPrice + InpBELockPrice, digits));
         if(newSL < bid - stopsLevel && (sl == 0.0 || newSL - sl >= InpTrailStepPrice))
            trade.PositionModify(ticket, newSL, newTP);
        }
      else
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask < startDist)
            continue;
         double newSL = NormalizeDouble(ask + trailDist, digits);
         newSL = MathMin(newSL, NormalizeDouble(openPrice - InpBELockPrice, digits));
         if(newSL > ask + stopsLevel && (sl == 0.0 || sl - newSL >= InpTrailStepPrice))
            trade.PositionModify(ticket, newSL, newTP);
        }
     }
  }

//+------------------------------------------------------------------+
void OnTrade()
  {
   g_statsDirty = true;
  }

//+------------------------------------------------------------------+
void RefreshStats()
  {
   if(!g_statsDirty)
      return;
   GetTodayStats(g_todayEntries, g_todayLosses, g_todayNet);
   GetAllTimeStats(g_allWins, g_allLosses, g_allNet);
   CleanupTP1Vars();
   g_statsDirty = false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayStart();
   RefreshStats();
   ManagePartialClose();
   ManageBreakEven();
   ManageTrailingStop();

   ENUM_TREND trend = GetH1Trend();

   // The new-bar flag is only consumed once every other filter passes, so a
   // momentary block on a bar's first tick (spread widening at bar open is
   // common on gold) doesn't throw away that bar's signal.
   string status = "waiting for setup";
   string limitReason = "";
   if(HasOpenPosition())
      status = "position open (single entry, no averaging)";
   else if(DailyLimitReached(limitReason))
      status = "stopped for today: " + limitReason;
   else if(!IsWithinTradingTime())
      status = "outside trading hours";
   else if(IsNewsBlackout())
      status = "news blackout";
   else if(!SpreadOK())
      status = StringFormat("spread too wide (%.2f > %.2f)", CurrentSpread(), InpMaxSpreadPrice);
   else if(trend == TREND_NONE && !(InpUseBreakout && !InpBreakoutTrendFilter))
      status = InpUseH4Filter ? "no trend (H1 + H4 not aligned)" : "no H1 trend";
   else if(IsNewEntryBar())
     {
      string reason;
      bool isBreakout;
      double slPrice;
      ENUM_TREND signal = GetEntrySignal(trend, reason, isBreakout, slPrice);
      if(signal != TREND_NONE)
        {
         status = StringFormat("%s signal %s", isBreakout ? "Breakout" : "Pullback",
                               signal == TREND_BUY ? "BUY" : "SELL");
         if(!TryOpen(signal, slPrice, isBreakout))
            status += " NOT opened - see Experts log";
        }
      else
         status = reason;
      g_lastStatus = status;
     }
   else
      status = g_lastStatus == "" ? status : g_lastStatus;

   // One debug line per entry-TF bar, so the Experts log shows why nothing traded.
   // When a filter (hours, news, spread, daily limit) blocked evaluation, the
   // signal is still checked here so a setup the filter threw away shows up as
   // "SKIPPED" instead of silently never happening.
   datetime barTime = iTime(_Symbol, InpEntryTimeframe, 0);
   if(InpDebugLog && barTime != g_lastLogBarTime)
     {
      g_lastLogBarTime = barTime;
      string trendStr = trend == TREND_BUY ? "BUY" : (trend == TREND_SELL ? "SELL" : "NONE");
      bool blocked = (status == "outside trading hours" || status == "news blackout" ||
                      StringFind(status, "spread too wide") == 0 || StringFind(status, "stopped for today") == 0);
      string skipped = "";
      if(blocked)
        {
         string reason;
         bool isBo;
         double slP;
         ENUM_TREND sig = GetEntrySignal(trend, reason, isBo, slP);
         if(sig != TREND_NONE)
           {
            skipped = StringFormat(" | %s signal SKIPPED", sig == TREND_BUY ? "BUY" : "SELL");
            g_lastSkipped = StringFormat("%s %s (%s)", sig == TREND_BUY ? "BUY" : "SELL",
                                         TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), status);
           }
        }
      PrintFormat("[%s] H1 trend=%s | %s%s", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
                  trendStr, status, skipped);
     }

   double atr[];
   double atrVal = (CopyBuffer(hATR, 0, 1, 1, atr) > 0) ? atr[0] : 0.0;
   int total = g_allWins + g_allLosses;
   double winRate = total > 0 ? 100.0 * g_allWins / total : 0.0;

   Comment(StringFormat("Gold Single Entry EA\nH1 trend: %s\nStatus: %s\n"
                        "Spread: %.2f (max %.2f)  ATR SL: %.2f (max %.2f)\n"
                        "Last skipped signal: %s\n"
                        "Trades: %d  Wins: %d  Losses: %d  Win rate: %.1f%%\nNet P/L: %.2f",
                        trend == TREND_BUY ? "BUY" : (trend == TREND_SELL ? "SELL" : "NONE"),
                        status, CurrentSpread(), InpMaxSpreadPrice, atrVal * InpSLATRMult, InpMaxSLPrice,
                        g_lastSkipped == "" ? "-" : g_lastSkipped, total, g_allWins, g_allLosses, winRate, g_allNet));
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Custom optimisation score (Strategy Tester -> Optimisation ->     |
//| "Custom max"). A pass only scores if it is profitable, has at     |
//| least InpOptMinTrades trades and a win rate >= InpOptMinWinRate;  |
//| among those it prefers a high profit factor, more trades (more    |
//| statistically meaningful) and a low drawdown. This keeps the      |
//| optimiser from picking a 100%-win-rate pass with 3 trades, or a   |
//| high-win-rate pass that still loses money.                        |
//+------------------------------------------------------------------+
double OnTester()
  {
   // Win rate per position (a partial close makes two exit deals per
   // trade, so the tester's deal-based STAT_TRADES would double-count).
   int w, l;
   double net;
   GetAllTimeStats(w, l, net);
   double trades = w + l;
   double wins   = w;
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(trades < InpOptMinTrades || profit <= 0.0)
      return 0.0;
   double winRate = 100.0 * wins / trades;
   if(winRate < InpOptMinWinRate)
      return 0.0;
   if(pf <= 0.0 || pf > 100.0)   // no losing trades at all reports PF as 0 or huge
      pf = 10.0;

   return pf * MathSqrt(trades) * (1.0 - MathMin(ddPct, 99.0) / 100.0);
  }
//+------------------------------------------------------------------+
