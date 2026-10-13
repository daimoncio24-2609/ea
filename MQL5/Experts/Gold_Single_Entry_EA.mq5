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

//--- Entry (pullback)
input group "=== Entry (Pullback) ==="
input ENUM_TIMEFRAMES InpEntryTimeframe = PERIOD_M15; // Entry timeframe
input int      InpRSIPeriod          = 14;      // RSI period on entry TF
input double   InpRSIBuyLevel        = 45.0;    // BUY: RSI must have dipped to/below this during the pullback
input double   InpRSISellLevel       = 55.0;    // SELL: RSI must have risen to/above this during the pullback
input double   InpRSITriggerLevel    = 50.0;    // Entry fires when RSI crosses back over this level (BUY: up, SELL: down)
input int      InpPullbackBars       = 12;      // How many recent closed bars the pullback may lie within

//--- SL / TP
input group "=== Stop Loss / Take Profit ==="
input int      InpATRPeriod          = 14;      // ATR period on entry TF
input double   InpSLATRMult          = 2.0;     // SL distance = ATR(entry TF) * this
input double   InpTPATRMult          = 1.0;     // TP distance = ATR(entry TF) * this
input double   InpMinSLPrice         = 3.0;     // Lower clamp for SL distance, in price units ($ for XAUUSD)
input double   InpMaxSLPrice         = 40.0;    // Skip the trade if the ATR SL is bigger than this, in price units ($)

//--- Break-even
input group "=== Break-even ==="
input bool     InpUseBreakEven       = true;    // Move SL to entry once the trade is far enough in profit
input double   InpBETriggerPercent   = 60.0;    // Trigger: price has covered this % of the TP distance
input double   InpBELockPrice        = 0.30;    // SL is placed this far past entry, in price units ($) - covers spread/commission

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
datetime       g_lastEntryBarTime = 0;
datetime       g_currentDayStart  = 0;
double         g_dayStartBalance  = 0.0;
string         g_lastStatus       = "";
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

   if(hEMAFastH1 == INVALID_HANDLE || hEMASlowH1 == INVALID_HANDLE || hADX_H1 == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handle(s).");
      return(INIT_FAILED);
     }

   if(InpTPATRMult >= InpSLATRMult)
      Print("Note: TP >= SL. Win rate will be lower than with the default TP < SL setup.");

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

   if(emaFast[0] > emaSlow[0] && closeH1 > emaSlow[0])
      return TREND_BUY;
   if(emaFast[0] < emaSlow[0] && closeH1 < emaSlow[0])
      return TREND_SELL;
   return TREND_NONE;
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
      return TREND_BUY;
     }

   if(rsiMax < InpRSISellLevel)
     { reason = StringFormat("SELL: waiting for pullback (max RSI %.1f < %.1f)", rsiMax, InpRSISellLevel); return TREND_NONE; }
   if(!(rsi[0] < InpRSITriggerLevel && rsi[1] >= InpRSITriggerLevel))
     { reason = StringFormat("SELL: pullback seen, waiting for RSI to cross down %.0f (now %.1f)", InpRSITriggerLevel, rsi[0]); return TREND_NONE; }
   if(close1 >= open1)
     { reason = "SELL: trigger bar not bearish"; return TREND_NONE; }
   return TREND_SELL;
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
//| Today's entries, closed losing trades and closed net P/L for      |
//| this symbol/magic, from the deal history.                         |
//+------------------------------------------------------------------+
void GetTodayStats(int &entries, int &losses, double &netProfit)
  {
   entries = 0;
   losses = 0;
   netProfit = 0.0;
   if(!HistorySelect(g_currentDayStart, TimeCurrent() + 60))
      return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
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
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
        {
         double p = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                    HistoryDealGetDouble(deal, DEAL_SWAP) +
                    HistoryDealGetDouble(deal, DEAL_COMMISSION);
         netProfit += p;
         if(p < 0.0)
            losses++;
        }
     }
  }

//+------------------------------------------------------------------+
//| All-time win/loss count for this symbol/magic (for the on-chart   |
//| comment). A trade closed at break-even + InpBELockPrice counts    |
//| as a (small) win, since its net result is positive.               |
//+------------------------------------------------------------------+
void GetAllTimeStats(int &wins, int &losses, double &netProfit)
  {
   wins = 0;
   losses = 0;
   netProfit = 0.0;
   if(!HistorySelect(0, TimeCurrent() + 60))
      return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      double p = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                 HistoryDealGetDouble(deal, DEAL_SWAP) +
                 HistoryDealGetDouble(deal, DEAL_COMMISSION);
      netProfit += p;
      if(p > 0.0)
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

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   return NormalizeLots(riskMoney / MathAbs(lossPerLot));
  }

//+------------------------------------------------------------------+
void TryOpen(ENUM_TREND signal)
  {
   double atr[];
   if(CopyBuffer(hATR, 0, 1, 1, atr) <= 0 || atr[0] <= 0.0)
      return;

   double slDist = atr[0] * InpSLATRMult;
   double tpDist = atr[0] * InpTPATRMult;
   double minSL  = InpMinSLPrice;
   double maxSL  = InpMaxSLPrice;
   if(slDist > maxSL)
     {
      PrintFormat("Skip: ATR-based SL %.2f exceeds InpMaxSLPrice %.2f (market too volatile).", slDist, maxSL);
      return;
     }
   if(slDist < minSL)
     {
      // keep the TP:SL ratio when the SL is clamped up
      tpDist *= minSL / slDist;
      slDist  = minSL;
     }

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(tpDist <= stopsLevel || slDist <= stopsLevel)
     {
      PrintFormat("Skip: TP %.2f / SL %.2f inside broker stops level %.2f.", tpDist, slDist, stopsLevel);
      return;
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(signal == TREND_BUY)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = NormalizeDouble(ask + tpDist, digits);
      double lots = CalcLots(ORDER_TYPE_BUY, ask, sl);
      if(!trade.Buy(lots, _Symbol, ask, sl, tp, "Gold single entry BUY"))
         PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else if(signal == TREND_SELL)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = NormalizeDouble(bid - tpDist, digits);
      double lots = CalcLots(ORDER_TYPE_SELL, bid, sl);
      if(!trade.Sell(lots, _Symbol, bid, sl, tp, "Gold single entry SELL"))
         PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
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
      if(tp <= 0.0)
         continue;

      double tpDist = MathAbs(tp - openPrice);
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
   g_statsDirty = false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayStart();
   RefreshStats();
   ManageBreakEven();

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
   else if(trend == TREND_NONE)
      status = "no H1 trend";
   else if(IsNewEntryBar())
     {
      string reason;
      ENUM_TREND signal = GetPullbackSignal(trend, reason);
      if(signal != TREND_NONE)
        {
         status = "signal " + (signal == TREND_BUY ? "BUY" : "SELL");
         TryOpen(signal);
        }
      else
         status = reason;
      g_lastStatus = status;
     }
   else
      status = g_lastStatus == "" ? status : g_lastStatus;

   // One debug line per entry-TF bar, so the Experts log shows why nothing traded
   datetime barTime = iTime(_Symbol, InpEntryTimeframe, 0);
   if(InpDebugLog && barTime != g_lastLogBarTime)
     {
      g_lastLogBarTime = barTime;
      PrintFormat("[%s] H1 trend=%s | %s", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
                  trend == TREND_BUY ? "BUY" : (trend == TREND_SELL ? "SELL" : "NONE"), status);
     }

   double atr[];
   double atrVal = (CopyBuffer(hATR, 0, 1, 1, atr) > 0) ? atr[0] : 0.0;
   int total = g_allWins + g_allLosses;
   double winRate = total > 0 ? 100.0 * g_allWins / total : 0.0;

   Comment(StringFormat("Gold Single Entry EA\nH1 trend: %s\nStatus: %s\n"
                        "Spread: %.2f (max %.2f)  ATR SL: %.2f (max %.2f)\n"
                        "Trades: %d  Wins: %d  Losses: %d  Win rate: %.1f%%\nNet P/L: %.2f",
                        trend == TREND_BUY ? "BUY" : (trend == TREND_SELL ? "SELL" : "NONE"),
                        status, CurrentSpread(), InpMaxSpreadPrice, atrVal * InpSLATRMult, InpMaxSLPrice,
                        total, g_allWins, g_allLosses, winRate, g_allNet));
  }
//+------------------------------------------------------------------+
