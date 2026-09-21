//+------------------------------------------------------------------+
//|                                       ADX_Trend_Scalper_EA.mq5  |
//|  H1 ADX trend filter + lower-timeframe entry + point/ATR grid. |
//+------------------------------------------------------------------+
#property copyright "Scalping ADX Trend EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- H1 trend filter (ADX)
input group "=== Trend Filter (H1 ADX) ==="
input int      InpADXPeriodH1        = 14;      // ADX period on H1
input double   InpADXTrendLevel      = 25.0;    // ADX level that confirms a trend
input double   InpMinDISpreadH1      = 5.0;     // Min. DI+/DI- separation on H1 to accept a trend (rejects a razor-thin DI cross)

//--- Entry timeframe
input group "=== Entry Timeframe ==="
enum ENUM_ENTRY_TF
  {
   ENTRY_TF_M1  = PERIOD_M1,
   ENTRY_TF_M5  = PERIOD_M5,
   ENTRY_TF_M15 = PERIOD_M15
  };
input ENUM_ENTRY_TF InpEntryTimeframe = ENTRY_TF_M15; // Entry timeframe (M1/M5/M15)
input int      InpADXPeriodEntry     = 14;      // ADX period on entry timeframe
input double   InpADXMinLevelEntry   = 20.0;    // Min. ADX on the entry timeframe to accept a signal (filters choppy/no-momentum bars)
input double   InpMinDISpreadEntry   = 5.0;     // Min. DI+/DI- separation on the entry timeframe to accept a signal

//--- Money management / averaging
input group "=== Lot & Averaging ==="
input double   InpLots                 = 0.01;  // Base/minimum lot size
input bool     InpUseCompounding        = false; // Scale lot with account balance (compounding)
input double   InpCompoundingBalanceStep = 100.0; // Balance increment that adds one InpCompoundingLotIncrement (tune to your account!)
input double   InpCompoundingLotIncrement = 0.01; // Lot added per InpCompoundingBalanceStep of balance
input double   InpMaxLots               = 1.0;   // Maximum lot size cap (with or without compounding)
enum ENUM_AVG_MODE
  {
   AVG_MODE_FIXED_POINTS,  // Fixed distance in points
   AVG_MODE_ATR            // Distance = ATR(H1) * multiplier
  };
input ENUM_AVG_MODE InpAveragingMode    = AVG_MODE_ATR; // Averaging distance mode
input double   InpAveragingPoints      = 500.0; // Fixed distance between averaging orders, in points (used when mode = Fixed points)
input int      InpATRPeriod            = 14;    // ATR period on H1 (used when mode = ATR)
input double   InpATRMultiplier        = 3.0;   // Averaging distance = ATR(H1) * this (used when mode = ATR)
input int      InpMaxAveragingOrders   = 5;     // Max open orders per basket (incl. first)
enum ENUM_TP_MODE
  {
   TP_MODE_FIXED_POINTS,  // Fixed distance in points
   TP_MODE_ATR            // Distance = ATR(H1) * multiplier
  };
input ENUM_TP_MODE InpTakeProfitMode   = TP_MODE_ATR; // Basket take-profit distance mode
input double   InpTakeProfitPoints     = 200.0; // Basket close target from average price, in points (used when mode = Fixed points)
input double   InpTPATRMultiplier      = 1.5;   // Basket TP distance = ATR(H1) * this (used when mode = ATR)

//--- Filters / identification
input group "=== Filters ==="
input int      InpMaxSpreadPoints      = 50;    // Max allowed spread (points)
input int      InpMagicNumber          = 202609;// Magic number
input int      InpSlippagePoints       = 10;    // Max deviation for orders (points)

//--- Time filter
input group "=== Time Filter (broker/server time) ==="
input bool     InpUseTimeFilter        = true;  // Enable trading-hours filter
input int      InpStartHour            = 8;     // Start hour (0-23) -- default targets the London/NY session overlap
input int      InpStartMinute          = 0;     // Start minute (0-59)
input int      InpEndHour              = 21;    // End hour (0-23)
input int      InpEndMinute            = 0;     // End minute (0-59)
input bool     InpTradeMonday          = true;
input bool     InpTradeTuesday         = true;
input bool     InpTradeWednesday       = true;
input bool     InpTradeThursday        = true;
input bool     InpTradeFriday          = true;
input bool     InpTradeSaturday        = false;
input bool     InpTradeSunday          = false;
input bool     InpUseFridayEarlyClose  = true;  // On Friday, stop new entries earlier
input int      InpFridayEndHour        = 14;    // Friday cutoff hour (0-23)
input int      InpFridayEndMinute      = 0;     // Friday cutoff minute (0-59)

//--- News filter
input group "=== News Filter ==="
input bool     InpUseNewsFilter        = true;  // Pause new entries/averaging around high-impact news
input int      InpNewsMinutesBefore    = 30;    // Minutes before a qualifying event to start the blackout
input int      InpNewsMinutesAfter     = 30;    // Minutes after a qualifying event to end the blackout
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum event importance treated as "news"

//--- Daily profit target
input group "=== Daily Target ==="
input bool     InpUseDailyTarget       = true;  // Stop trading once the daily target is hit
input double   InpDailyTargetPercent   = 20.0;  // Daily profit target, % of account balance at day start
input bool     InpCloseAllOnDailyTarget = true; // Close all open positions once the target is hit

//--- Risk control
input group "=== Risk Control ==="
input bool     InpUseMaxFloatingLoss    = true;  // Force-close a basket if its floating loss gets too big
input double   InpMaxFloatingLossPercent = 10.0; // Max floating loss per basket, % of account balance

//--- Trailing stop (per position, broker-side SL)
input group "=== Trailing Stop ==="
input bool     InpUseTrailingStop       = true;  // Enable per-position trailing stop
input int      InpTrailingStopPoints    = 300;   // Trailing distance behind price, points
input int      InpTrailingStepPoints    = 200;   // Min. improvement before the SL is moved again, points

CTrade         trade;
int            hADX_H1    = INVALID_HANDLE;
int            hADX_Entry = INVALID_HANDLE;
int            hATR_H1    = INVALID_HANDLE;
datetime       g_lastEntryBarTime = 0;
datetime       g_currentDayStart  = 0;
double         g_dayStartBalance  = 0.0;
bool           g_dailyTargetHit   = false;

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

   hADX_H1    = iADX(_Symbol, PERIOD_H1, InpADXPeriodH1);
   hADX_Entry = iADX(_Symbol, (ENUM_TIMEFRAMES)InpEntryTimeframe, InpADXPeriodEntry);
   hATR_H1    = iATR(_Symbol, PERIOD_H1, InpATRPeriod);

   if(hADX_H1 == INVALID_HANDLE || hADX_Entry == INVALID_HANDLE || hATR_H1 == INVALID_HANDLE)
     {
      Print("Failed to create indicator handle(s).");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hADX_H1 != INVALID_HANDLE)
      IndicatorRelease(hADX_H1);
   if(hADX_Entry != INVALID_HANDLE)
      IndicatorRelease(hADX_Entry);
   if(hATR_H1 != INVALID_HANDLE)
      IndicatorRelease(hATR_H1);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Distance (in price units) between averaging orders. Using raw    |
//| broker points (or ATR) instead of an FX-style "pip" avoids        |
//| misclassifying non-forex symbols (e.g. XAUUSD quoted with 2       |
//| decimals), where a pip-based distance could end up far smaller    |
//| than intended.                                                   |
//+------------------------------------------------------------------+
double AveragingDistance()
  {
   if(InpAveragingMode == AVG_MODE_ATR)
     {
      double atr[];
      if(CopyBuffer(hATR_H1, 0, 1, 1, atr) > 0 && atr[0] > 0.0)
         return atr[0] * InpATRMultiplier;
     }
   return InpAveragingPoints * _Point;
  }

//+------------------------------------------------------------------+
//| Basket take-profit distance (in price units) from the average    |
//| open price. Same rationale as AveragingDistance(): a fixed point  |
//| value only really suits one type of instrument, so an ATR-based   |
//| mode is offered to auto-scale with each symbol's real volatility. |
//+------------------------------------------------------------------+
double TakeProfitDistance()
  {
   if(InpTakeProfitMode == TP_MODE_ATR)
     {
      double atr[];
      if(CopyBuffer(hATR_H1, 0, 1, 1, atr) > 0 && atr[0] > 0.0)
         return atr[0] * InpTPATRMultiplier;
     }
   return InpTakeProfitPoints * _Point;
  }

//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= InpMaxSpreadPoints;
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
      case 0: dayAllowed = InpTradeSunday;    break;
      case 1: dayAllowed = InpTradeMonday;    break;
      case 2: dayAllowed = InpTradeTuesday;   break;
      case 3: dayAllowed = InpTradeWednesday; break;
      case 4: dayAllowed = InpTradeThursday;  break;
      case 5: dayAllowed = InpTradeFriday;    break;
      default: dayAllowed = InpTradeSaturday; break;
     }
   if(!dayAllowed)
      return false;

   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = InpStartHour * 60 + InpStartMinute;
   int endMinutes   = InpEndHour * 60 + InpEndMinute;

   // Friday gets its own (earlier) cutoff to reduce weekend-gap exposure
   if(dt.day_of_week == 5 && InpUseFridayEarlyClose)
      endMinutes = InpFridayEndHour * 60 + InpFridayEndMinute;

   if(startMinutes <= endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= endMinutes);

   // window wraps past midnight (e.g. 22:00 -> 05:00)
   return (nowMinutes >= startMinutes || nowMinutes <= endMinutes);
  }

//+------------------------------------------------------------------+
//| True while "now" falls within InpNewsMinutesBefore/After of a     |
//| qualifying calendar event for the symbol's base or profit         |
//| currency. Uses the terminal's built-in Economic Calendar, so it   |
//| needs the calendar to be available/synced (works in live/demo;    |
//| in the Strategy Tester it depends on downloaded calendar history  |
//| being available for the tested period). Result is cached for a   |
//| minute since scanning the calendar every tick is unnecessary.     |
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
//| H1 trend: DI+ > DI- and ADX > level => BUY, DI- > DI+ and        |
//| ADX > level => SELL, otherwise no trend. Also requires the DI+/  |
//| DI- gap to clear InpMinDISpreadH1, so a razor-thin cross (won by  |
//| a fraction of a point) doesn't count as a real trend.            |
//+------------------------------------------------------------------+
ENUM_TREND GetH1Trend()
  {
   double adx[], plusDI[], minusDI[];
   if(CopyBuffer(hADX_H1, MAIN_LINE, 1, 1, adx) <= 0)    return TREND_NONE;
   if(CopyBuffer(hADX_H1, PLUSDI_LINE, 1, 1, plusDI) <= 0)  return TREND_NONE;
   if(CopyBuffer(hADX_H1, MINUSDI_LINE, 1, 1, minusDI) <= 0) return TREND_NONE;

   if(adx[0] > InpADXTrendLevel && plusDI[0] - minusDI[0] >= InpMinDISpreadH1)
      return TREND_BUY;
   if(adx[0] > InpADXTrendLevel && minusDI[0] - plusDI[0] >= InpMinDISpreadH1)
      return TREND_SELL;
   return TREND_NONE;
  }

//+------------------------------------------------------------------+
//| Directional bias on the entry timeframe. Three extra conditions  |
//| on top of the plain DI+/DI- comparison, all aimed at cutting down |
//| false/whipsaw entries on the (usually noisier) lower timeframe:   |
//| 1) ADX on the entry TF must clear InpADXMinLevelEntry - a bare DI |
//|    cross during a flat/choppy stretch is rejected.                |
//| 2) The DI+/DI- gap must clear InpMinDISpreadEntry - a razor-thin  |
//|    cross (won by a fraction of a point) doesn't count.            |
//| 3) The (qualifying) cross must be fresh: the previous closed bar  |
//|    must NOT already have qualified, so this only fires right as   |
//|    the cross happens instead of every bar afterwards while it     |
//|    happens to still hold (which is often a late entry).           |
//+------------------------------------------------------------------+
ENUM_TREND GetEntryBias()
  {
   double adx[], plusDI[], minusDI[];
   if(CopyBuffer(hADX_Entry, MAIN_LINE, 1, 1, adx) <= 0)
      return TREND_NONE;
   if(CopyBuffer(hADX_Entry, PLUSDI_LINE, 1, 2, plusDI) < 2)
      return TREND_NONE;
   if(CopyBuffer(hADX_Entry, MINUSDI_LINE, 1, 2, minusDI) < 2)
      return TREND_NONE;

   if(adx[0] < InpADXMinLevelEntry)
      return TREND_NONE;

   bool buyNow   = (plusDI[0]  - minusDI[0]) >= InpMinDISpreadEntry;
   bool buyPrev  = (plusDI[1]  - minusDI[1]) >= InpMinDISpreadEntry;
   bool sellNow  = (minusDI[0] - plusDI[0])  >= InpMinDISpreadEntry;
   bool sellPrev = (minusDI[1] - plusDI[1])  >= InpMinDISpreadEntry;

   if(buyNow && !buyPrev)
      return TREND_BUY;
   if(sellNow && !sellPrev)
      return TREND_SELL;
   return TREND_NONE;
  }

//+------------------------------------------------------------------+
bool IsNewEntryBar()
  {
   datetime t = iTime(_Symbol, (ENUM_TIMEFRAMES)InpEntryTimeframe, 0);
   if(t != g_lastEntryBarTime)
     {
      g_lastEntryBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Count open positions (this symbol/magic) in one direction and    |
//| return the most adverse (extreme) open price for grid spacing    |
//+------------------------------------------------------------------+
int CountPositions(ENUM_TREND direction, double &extremePrice)
  {
   int count = 0;
   extremePrice = (direction == TREND_BUY) ? DBL_MAX : -DBL_MAX;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == TREND_BUY  && ptype != POSITION_TYPE_BUY)  continue;
      if(direction == TREND_SELL && ptype != POSITION_TYPE_SELL) continue;

      count++;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(direction == TREND_BUY  && openPrice < extremePrice) extremePrice = openPrice;
      if(direction == TREND_SELL && openPrice > extremePrice) extremePrice = openPrice;
     }
   return count;
  }

//+------------------------------------------------------------------+
int TotalPositionsForSymbolMagic()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Volume-weighted average open price of a basket                   |
//+------------------------------------------------------------------+
double AveragePrice(ENUM_TREND direction, double &totalVolume)
  {
   double sumPriceVol = 0.0;
   totalVolume = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == TREND_BUY  && ptype != POSITION_TYPE_BUY)  continue;
      if(direction == TREND_SELL && ptype != POSITION_TYPE_SELL) continue;

      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      sumPriceVol += vol * price;
      totalVolume += vol;
     }

   if(totalVolume <= 0.0)
      return 0.0;
   return sumPriceVol / totalVolume;
  }

//+------------------------------------------------------------------+
//| Lot size for a brand-new basket. Proportional to the account       |
//| balance at the start of the day (so it scales down again during   |
//| a drawdown, not just up), floored at InpLots and capped at        |
//| InpMaxLots. Every InpCompoundingBalanceStep of balance adds one    |
//| InpCompoundingLotIncrement -- tune both to your account size.     |
//+------------------------------------------------------------------+
double ComputeLotSize()
  {
   double lot = InpLots;

   if(InpUseCompounding && InpCompoundingBalanceStep > 0.0)
     {
      double balance = (g_dayStartBalance > 0.0) ? g_dayStartBalance : AccountInfoDouble(ACCOUNT_BALANCE);
      double steps   = MathFloor(balance / InpCompoundingBalanceStep);
      lot = InpLots + steps * InpCompoundingLotIncrement;
     }

   lot = MathMax(InpLots, MathMin(InpMaxLots, lot));

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lotStep > 0.0)
      lot = MathRound(lot / lotStep) * lotStep;
   lot = MathMax(minVol, MathMin(maxVol, lot));

   return lot;
  }

//+------------------------------------------------------------------+
//| Lot size already used by an existing basket, so averaging orders  |
//| match the lot the basket was opened with instead of picking up a  |
//| freshly-compounded size mid-basket. Returns 0 if the basket is    |
//| empty (caller should fall back to ComputeLotSize()).              |
//+------------------------------------------------------------------+
double GetBasketLot(ENUM_TREND direction)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == TREND_BUY  && ptype != POSITION_TYPE_BUY)  continue;
      if(direction == TREND_SELL && ptype != POSITION_TYPE_SELL) continue;

      return PositionGetDouble(POSITION_VOLUME);
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Sum of floating profit (+ swap) for one basket (this symbol/magic |
//| direction). Negative means the basket is underwater.              |
//+------------------------------------------------------------------+
double BasketFloatingProfit(ENUM_TREND direction)
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == TREND_BUY  && ptype != POSITION_TYPE_BUY)  continue;
      if(direction == TREND_SELL && ptype != POSITION_TYPE_SELL) continue;

      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

//+------------------------------------------------------------------+
void CloseDirection(ENUM_TREND direction)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(direction == TREND_BUY  && ptype != POSITION_TYPE_BUY)  continue;
      if(direction == TREND_SELL && ptype != POSITION_TYPE_SELL) continue;

      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Hard risk cap: since averaging has no per-order stop loss, force- |
//| close a whole basket if its own floating loss reaches             |
//| InpMaxFloatingLossPercent of the account balance. Checked          |
//| independently per side (BUY/SELL), every tick, regardless of the  |
//| time filter or daily target state.                                 |
//+------------------------------------------------------------------+
void CheckMaxFloatingLoss()
  {
   if(!InpUseMaxFloatingLoss)
      return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return;

   double maxLoss = balance * InpMaxFloatingLossPercent / 100.0;

   double buyProfit = BasketFloatingProfit(TREND_BUY);
   if(buyProfit < 0.0 && -buyProfit >= maxLoss)
     {
      PrintFormat("Max floating loss hit on BUY basket: %.2f (limit -%.2f = %.1f%% of balance %.2f). Closing basket.",
                  buyProfit, maxLoss, InpMaxFloatingLossPercent, balance);
      CloseDirection(TREND_BUY);
     }

   double sellProfit = BasketFloatingProfit(TREND_SELL);
   if(sellProfit < 0.0 && -sellProfit >= maxLoss)
     {
      PrintFormat("Max floating loss hit on SELL basket: %.2f (limit -%.2f = %.1f%% of balance %.2f). Closing basket.",
                  sellProfit, maxLoss, InpMaxFloatingLossPercent, balance);
      CloseDirection(TREND_SELL);
     }
  }

//+------------------------------------------------------------------+
//| Per-position trailing stop (broker-side SL). Once a position is   |
//| more than InpTrailingStopPoints in profit, its SL trails behind   |
//| price at that same distance, only moving again once the           |
//| improvement reaches InpTrailingStepPoints. This works alongside,  |
//| not instead of, the basket-level take-profit/max-loss checks:     |
//| whichever condition is met first closes the position(s).          |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
  {
   if(!InpUseTrailingStop)
      return;

   double stopDistance = InpTrailingStopPoints * _Point;
   double stepDistance  = InpTrailingStepPoints * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE ptype    = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             currentSL = PositionGetDouble(POSITION_SL);
      double             tp        = PositionGetDouble(POSITION_TP);

      if(ptype == POSITION_TYPE_BUY)
        {
         if(bid - openPrice <= stopDistance)
            continue;
         double newSL = bid - stopDistance;
         if(currentSL == 0.0 || newSL - currentSL >= stepDistance)
            trade.PositionModify(ticket, newSL, tp);
        }
      else if(ptype == POSITION_TYPE_SELL)
        {
         if(openPrice - ask <= stopDistance)
            continue;
         double newSL = ask + stopDistance;
         if(currentSL == 0.0 || currentSL - newSL >= stepDistance)
            trade.PositionModify(ticket, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Roll over the daily profit target at the start of each new day    |
//| (broker/server time), using the account balance at that moment   |
//| as the day's baseline.                                            |
//+------------------------------------------------------------------+
void RolloverDailyTarget()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(dayStart != g_currentDayStart)
     {
      g_currentDayStart = dayStart;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyTargetHit  = false;
     }
  }

//+------------------------------------------------------------------+
//| Once today's profit (equity - balance at day start) reaches       |
//| InpDailyTargetPercent of that starting balance, stop opening new  |
//| trades for the rest of the day and optionally flatten everything  |
//| to lock the gain in. Note: this looks at the whole account's      |
//| equity/balance, not just this EA's positions.                     |
//+------------------------------------------------------------------+
void CheckDailyTarget()
  {
   RolloverDailyTarget();

   if(!InpUseDailyTarget || g_dailyTargetHit || g_dayStartBalance <= 0.0)
      return;

   double profit       = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance;
   double targetProfit = g_dayStartBalance * InpDailyTargetPercent / 100.0;

   if(profit >= targetProfit)
     {
      g_dailyTargetHit = true;
      PrintFormat("Daily target reached: profit %.2f >= target %.2f (%.1f%% of %.2f). Trading paused for today.",
                  profit, targetProfit, InpDailyTargetPercent, g_dayStartBalance);
      if(InpCloseAllOnDailyTarget)
        {
         CloseDirection(TREND_BUY);
         CloseDirection(TREND_SELL);
        }
     }
  }

//+------------------------------------------------------------------+
//| Close a basket once price reaches TP distance from its average   |
//| open price (lets a losing average recover instead of never       |
//| closing at all)                                                  |
//+------------------------------------------------------------------+
void CheckBasketTakeProfit()
  {
   double tpDistance = TakeProfitDistance();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double volBuy = 0.0;
   double avgBuy = AveragePrice(TREND_BUY, volBuy);
   if(volBuy > 0.0 && bid >= avgBuy + tpDistance)
      CloseDirection(TREND_BUY);

   double volSell = 0.0;
   double avgSell = AveragePrice(TREND_SELL, volSell);
   if(volSell > 0.0 && ask <= avgSell - tpDistance)
      CloseDirection(TREND_SELL);
  }

//+------------------------------------------------------------------+
void OpenMarket(ENUM_TREND direction, double lot, string comment)
  {
   if(direction == TREND_BUY)
      trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment);
   else
      if(direction == TREND_SELL)
         trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);
  }

//+------------------------------------------------------------------+
//| Add an averaging order every AveragingDistance() against the     |
//| existing basket, up to InpMaxAveragingOrders positions total.    |
//| Only averages while the H1 trend still agrees with the basket's  |
//| direction, so a trend flip stops the basket from growing further |
//| against the new H1 bias. Uses the basket's own existing lot size |
//| (GetBasketLot) rather than recomputing compounding mid-basket.   |
//+------------------------------------------------------------------+
void ManageAveraging(ENUM_TREND h1Trend)
  {
   double distance = AveragingDistance();
   double extremePrice;

   int buyCount = CountPositions(TREND_BUY, extremePrice);
   if(buyCount > 0 && buyCount < InpMaxAveragingOrders && h1Trend == TREND_BUY)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask <= extremePrice - distance)
        {
         double lot = GetBasketLot(TREND_BUY);
         if(lot <= 0.0) lot = ComputeLotSize();
         OpenMarket(TREND_BUY, lot, "ADX-Scalper avg buy");
        }
     }

   int sellCount = CountPositions(TREND_SELL, extremePrice);
   if(sellCount > 0 && sellCount < InpMaxAveragingOrders && h1Trend == TREND_SELL)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid >= extremePrice + distance)
        {
         double lot = GetBasketLot(TREND_SELL);
         if(lot <= 0.0) lot = ComputeLotSize();
         OpenMarket(TREND_SELL, lot, "ADX-Scalper avg sell");
        }
     }
  }

//+------------------------------------------------------------------+
//| Open the first order of a NEW basket in the current H1 trend      |
//| direction. This only checks whether a basket already exists in   |
//| that same direction (not whether the symbol is flat overall), so |
//| when H1 flips trend a fresh basket is opened on the new side      |
//| while any existing basket on the other side is left untouched -  |
//| it keeps averaging on its own once H1 swings back to agree with  |
//| it (see ManageAveraging). The lot for this new basket is fixed by |
//| ComputeLotSize() at open time and reused for its future averaging |
//| orders, so compounding can't drift a single basket's lot size.   |
//+------------------------------------------------------------------+
void CheckNewEntry(ENUM_TREND h1Trend)
  {
   if(h1Trend == TREND_NONE)
      return;

   double extremePrice;
   if(CountPositions(h1Trend, extremePrice) > 0)
      return; // a basket already exists on this side; ManageAveraging handles it

   ENUM_TREND entryBias = GetEntryBias();
   if(entryBias == h1Trend)
      OpenMarket(h1Trend, ComputeLotSize(), "ADX-Scalper entry");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(hADX_H1 == INVALID_HANDLE || hADX_Entry == INVALID_HANDLE)
      return;

   ENUM_TREND h1Trend = GetH1Trend();

   CheckBasketTakeProfit();
   CheckMaxFloatingLoss();
   ApplyTrailingStop();
   CheckDailyTarget();

   bool timeOK  = IsWithinTradingTime();
   bool newsOK  = !IsNewsBlackout();

   if(SpreadOK() && timeOK && newsOK && !g_dailyTargetHit)
     {
      ManageAveraging(h1Trend);
      if(IsNewEntryBar())
         CheckNewEntry(h1Trend);
     }

   double dailyProfit  = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance;
   double dailyPercent = (g_dayStartBalance > 0.0) ? dailyProfit / g_dayStartBalance * 100.0 : 0.0;
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double buyFloating  = BasketFloatingProfit(TREND_BUY);
   double sellFloating = BasketFloatingProfit(TREND_SELL);
   double maxLoss      = balance * InpMaxFloatingLossPercent / 100.0;

   string trendStr = (h1Trend == TREND_BUY) ? "BUY" : (h1Trend == TREND_SELL) ? "SELL" : "NONE";
   Comment(StringFormat(
           "ADX Trend Scalper (magic %d)\nH1 trend: %s\nSpread: %d pts (max %d)\nTrading time: %s | News: %s\nAveraging distance: %.0f pts | TP distance: %.0f pts\nDaily P/L: %.2f (%.1f%% / target %.1f%%)%s\nBUY basket: %.2f | SELL basket: %.2f (max loss -%.2f)\nOpen positions: %d",
           InpMagicNumber, trendStr, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
           InpMaxSpreadPoints, timeOK ? "OK" : "closed", newsOK ? "OK" : "blackout",
           AveragingDistance() / _Point, TakeProfitDistance() / _Point,
           dailyProfit, dailyPercent, InpDailyTargetPercent,
           g_dailyTargetHit ? " [TARGET HIT]" : "",
           buyFloating, sellFloating, maxLoss,
           TotalPositionsForSymbolMagic()));
  }
//+------------------------------------------------------------------+
