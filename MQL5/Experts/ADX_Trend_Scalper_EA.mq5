//+------------------------------------------------------------------+
//|                                       ADX_Trend_Scalper_EA.mq5  |
//|  H1 ADX trend filter + lower-timeframe entry + pip averaging.  |
//+------------------------------------------------------------------+
#property copyright "Scalping ADX Trend EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- H1 trend filter (ADX)
input group "=== Trend Filter (H1 ADX) ==="
input int      InpADXPeriodH1        = 14;      // ADX period on H1
input double   InpADXTrendLevel      = 25.0;    // ADX level that confirms a trend

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

//--- Money management / averaging
input group "=== Lot & Averaging ==="
input double   InpLots                 = 0.01;  // Lot size (fixed for every order)
input double   InpAveragingPips        = 500.0; // Distance between averaging orders (pips)
input int      InpMaxAveragingOrders   = 10;    // Max open orders per basket (incl. first)
input double   InpTakeProfitPips       = 20.0;  // Basket close target from average price (pips)

//--- Filters / identification
input group "=== Filters ==="
input int      InpMaxSpreadPoints      = 50;    // Max allowed spread (points)
input int      InpMagicNumber          = 202609;// Magic number
input int      InpSlippagePoints       = 10;    // Max deviation for orders (points)

CTrade         trade;
int            hADX_H1    = INVALID_HANDLE;
int            hADX_Entry = INVALID_HANDLE;
datetime       g_lastEntryBarTime = 0;

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

   if(hADX_H1 == INVALID_HANDLE || hADX_Entry == INVALID_HANDLE)
     {
      Print("Failed to create ADX indicator handle(s).");
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
   Comment("");
  }

//+------------------------------------------------------------------+
//| Pip size (1 pip = 10 points on 3/5-digit symbols)                |
//+------------------------------------------------------------------+
double PipSize()
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (digits == 3 || digits == 5) ? point * 10.0 : point;
  }

//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= InpMaxSpreadPoints;
  }

//+------------------------------------------------------------------+
//| H1 trend: DI+ > DI- and ADX > level => BUY, DI- > DI+ and        |
//| ADX > level => SELL, otherwise no trend                          |
//+------------------------------------------------------------------+
ENUM_TREND GetH1Trend()
  {
   double adx[], plusDI[], minusDI[];
   if(CopyBuffer(hADX_H1, MAIN_LINE, 1, 1, adx) <= 0)    return TREND_NONE;
   if(CopyBuffer(hADX_H1, PLUSDI_LINE, 1, 1, plusDI) <= 0)  return TREND_NONE;
   if(CopyBuffer(hADX_H1, MINUSDI_LINE, 1, 1, minusDI) <= 0) return TREND_NONE;

   if(adx[0] > InpADXTrendLevel && plusDI[0] > minusDI[0])
      return TREND_BUY;
   if(adx[0] > InpADXTrendLevel && minusDI[0] > plusDI[0])
      return TREND_SELL;
   return TREND_NONE;
  }

//+------------------------------------------------------------------+
//| Directional bias on the entry timeframe (DI+ vs DI-)             |
//+------------------------------------------------------------------+
ENUM_TREND GetEntryBias()
  {
   double plusDI[], minusDI[];
   if(CopyBuffer(hADX_Entry, PLUSDI_LINE, 1, 1, plusDI) <= 0)  return TREND_NONE;
   if(CopyBuffer(hADX_Entry, MINUSDI_LINE, 1, 1, minusDI) <= 0) return TREND_NONE;

   if(plusDI[0] > minusDI[0]) return TREND_BUY;
   if(minusDI[0] > plusDI[0]) return TREND_SELL;
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
//| Close a basket once price reaches TP distance from its average   |
//| open price (lets a losing average recover instead of never       |
//| closing at all)                                                  |
//+------------------------------------------------------------------+
void CheckBasketTakeProfit()
  {
   double pip = PipSize();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double volBuy = 0.0;
   double avgBuy = AveragePrice(TREND_BUY, volBuy);
   if(volBuy > 0.0 && bid >= avgBuy + InpTakeProfitPips * pip)
      CloseDirection(TREND_BUY);

   double volSell = 0.0;
   double avgSell = AveragePrice(TREND_SELL, volSell);
   if(volSell > 0.0 && ask <= avgSell - InpTakeProfitPips * pip)
      CloseDirection(TREND_SELL);
  }

//+------------------------------------------------------------------+
void OpenMarket(ENUM_TREND direction, string comment)
  {
   if(direction == TREND_BUY)
      trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, comment);
   else
      if(direction == TREND_SELL)
         trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, comment);
  }

//+------------------------------------------------------------------+
//| Add an averaging order every InpAveragingPips against the        |
//| existing basket, up to InpMaxAveragingOrders positions total.    |
//| Only averages while the H1 trend still agrees with the basket's  |
//| direction, so a trend flip stops the basket from growing further |
//| against the new H1 bias.                                         |
//+------------------------------------------------------------------+
void ManageAveraging(ENUM_TREND h1Trend)
  {
   double pip = PipSize();
   double extremePrice;

   int buyCount = CountPositions(TREND_BUY, extremePrice);
   if(buyCount > 0 && buyCount < InpMaxAveragingOrders && h1Trend == TREND_BUY)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask <= extremePrice - InpAveragingPips * pip)
         OpenMarket(TREND_BUY, "ADX-Scalper avg buy");
     }

   int sellCount = CountPositions(TREND_SELL, extremePrice);
   if(sellCount > 0 && sellCount < InpMaxAveragingOrders && h1Trend == TREND_SELL)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid >= extremePrice + InpAveragingPips * pip)
         OpenMarket(TREND_SELL, "ADX-Scalper avg sell");
     }
  }

//+------------------------------------------------------------------+
//| Open the first order of a basket: only when flat, H1 has a       |
//| confirmed trend, and the entry timeframe DI bias agrees with it  |
//+------------------------------------------------------------------+
void CheckNewEntry(ENUM_TREND h1Trend)
  {
   if(h1Trend == TREND_NONE)
      return;
   if(TotalPositionsForSymbolMagic() > 0)
      return;

   ENUM_TREND entryBias = GetEntryBias();
   if(entryBias == h1Trend)
      OpenMarket(h1Trend, "ADX-Scalper entry");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(hADX_H1 == INVALID_HANDLE || hADX_Entry == INVALID_HANDLE)
      return;

   ENUM_TREND h1Trend = GetH1Trend();

   CheckBasketTakeProfit();

   if(SpreadOK())
     {
      ManageAveraging(h1Trend);
      if(IsNewEntryBar())
         CheckNewEntry(h1Trend);
     }

   string trendStr = (h1Trend == TREND_BUY) ? "BUY" : (h1Trend == TREND_SELL) ? "SELL" : "NONE";
   Comment(StringFormat(
           "ADX Trend Scalper (magic %d)\nH1 trend: %s\nSpread: %d pts (max %d)\nOpen positions: %d",
           InpMagicNumber, trendStr, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
           InpMaxSpreadPoints, TotalPositionsForSymbolMagic()));
  }
//+------------------------------------------------------------------+
