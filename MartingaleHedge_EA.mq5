//+------------------------------------------------------------------+
//|                                         MartingaleHedge_EA.mq5   |
//|                              Copyright 2024, Prashant Pradhan    |
//|                                                                   |
//|  Martingale strategy for Gold (XAUUSD) with hedge drawdown       |
//|  protection. Signals are generated via EMA crossover.            |
//|                                                                   |
//|  Strategy overview:                                              |
//|   1. Enter on EMA fast/slow crossover.                           |
//|   2. If price moves against the trade by InpMartingaleGap        |
//|      points, open an additional position with a multiplied lot    |
//|      size (Martingale grid).                                     |
//|   3. If account drawdown exceeds InpHedgeDrawdown %, open a      |
//|      counter-direction hedge position to cap further losses.      |
//|   4. Close the hedge once the drawdown recovers.                 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Prashant Pradhan"
#property version   "1.00"
#property description "Martingale + Hedge EA for Gold (XAUUSD) on MT5"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input groups -------------------------------------------------
input group "=== Trade Settings ==="
input double   InpInitialLot      = 0.01;   // Initial Lot Size
input double   InpLotMultiplier   = 2.0;    // Martingale Lot Multiplier
input int      InpMaxSteps        = 6;      // Maximum Martingale Steps
input double   InpMaxLot          = 5.0;    // Maximum Single Lot Cap
input int      InpTakeProfit      = 500;    // Take Profit (points)
input int      InpStopLoss        = 0;      // Stop Loss in points (0 = disabled)
input int      InpMagicNumber     = 20241;  // Magic Number
input string   InpComment         = "MH_EA"; // Trade Comment

input group "=== Martingale Settings ==="
input int      InpMartingaleGap   = 500;    // Grid Gap (points) before adding next lot

input group "=== Hedge Settings ==="
input bool     InpUseHedge        = true;   // Enable Hedge Protection
input double   InpHedgeDrawdown   = 5.0;    // Drawdown % to trigger hedge
input double   InpHedgeLotFactor  = 1.5;    // Hedge Lot = total_lots * factor
input int      InpHedgeTP         = 300;    // Hedge Take Profit (points)

input group "=== Signal Settings ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1; // Signal Timeframe
input int      InpFastMA          = 10;     // Fast EMA Period
input int      InpSlowMA          = 20;     // Slow EMA Period
input bool     InpCloseOnOpposite = true;   // Close all on opposite crossover

//--- Global objects -----------------------------------------------
CTrade         g_trade;
CPositionInfo  g_pos;

//--- Indicator handles ---
int  g_fastHandle = INVALID_HANDLE;
int  g_slowHandle = INVALID_HANDLE;

//--- Indicator buffers ---
double g_fastBuf[];
double g_slowBuf[];

//--- State variables ---
int    g_step          = 0;      // Current Martingale step (0 = first trade)
int    g_direction     = 0;      // Active trade direction: 1=buy -1=sell 0=none
int    g_lastSignal    = 0;      // Last crossover signal
double g_nextLot       = 0.0;    // Lot for the next Martingale addition
bool   g_hedgeActive   = false;  // Is a hedge position currently open?
ulong  g_hedgeTicket   = 0;      // Ticket of the hedge position

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpFastMA >= InpSlowMA)
   {
      Print("ERROR: Fast MA period must be less than Slow MA period.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpInitialLot <= 0 || InpLotMultiplier <= 1.0)
   {
      Print("ERROR: InitialLot must be > 0 and LotMultiplier must be > 1.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Configure trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Create indicator handles
   g_fastHandle = iMA(_Symbol, InpTimeframe, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowHandle = iMA(_Symbol, InpTimeframe, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);

   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA handles: ", GetLastError());
      return INIT_FAILED;
   }

   ArraySetAsSeries(g_fastBuf, true);
   ArraySetAsSeries(g_slowBuf, true);

   g_nextLot = InpInitialLot;

   Print("MartingaleHedge EA started on ", _Symbol,
         " | Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
   if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only act on a new bar to avoid redundant work
   if(!IsNewBar()) return;

   //--- Refresh indicator buffers (need 3 bars: [0]=current [1]=closed [2]=prev-closed)
   if(CopyBuffer(g_fastHandle, 0, 0, 3, g_fastBuf) < 3) return;
   if(CopyBuffer(g_slowHandle, 0, 0, 3, g_slowBuf) < 3) return;

   //--- Hedge management runs every bar regardless of position state
   if(InpUseHedge)
      ManageHedge();

   int signal   = GetSignal();
   int totalPos = CountPositions(-1);

   if(totalPos == 0)
   {
      //--- No open positions: reset state and enter on any signal
      ResetState();
      if(signal != 0)
      {
         g_direction  = signal;
         g_lastSignal = signal;
         OpenTrade(signal, g_nextLot);
      }
   }
   else
   {
      //--- Martingale: add grid positions while no hedge is active
      if(!g_hedgeActive)
         CheckMartingale();

      //--- Reverse on opposite crossover if enabled
      if(InpCloseOnOpposite && signal != 0 && signal != g_lastSignal)
      {
         CloseAllPositions();
         ResetState();
         g_direction  = signal;
         g_lastSignal = signal;
         OpenTrade(signal, g_nextLot);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect EMA crossover on the last *closed* bar ([1] vs [2])       |
//+------------------------------------------------------------------+
int GetSignal()
{
   if(ArraySize(g_fastBuf) < 3 || ArraySize(g_slowBuf) < 3)
      return 0;

   bool bullCross = (g_fastBuf[1] > g_slowBuf[1]) && (g_fastBuf[2] <= g_slowBuf[2]);
   bool bearCross = (g_fastBuf[1] < g_slowBuf[1]) && (g_fastBuf[2] >= g_slowBuf[2]);

   if(bullCross) return  1;
   if(bearCross) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Open a market order                                               |
//+------------------------------------------------------------------+
bool OpenTrade(int direction, double lot)
{
   lot = NormalizeLot(lot);
   if(lot <= 0)
   {
      Print("WARNING: Normalized lot is 0 — skipping trade.");
      return false;
   }

   double price, tp = 0.0, sl = 0.0;
   string comment = InpComment + (direction == 1 ? "_B" : "_S") + IntegerToString(g_step);

   if(direction == 1)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(InpTakeProfit > 0) tp = price + InpTakeProfit * _Point;
      if(InpStopLoss  > 0) sl = price - InpStopLoss  * _Point;

      if(!g_trade.Buy(lot, _Symbol, price, sl, tp, comment))
      {
         Print("Buy failed (step=", g_step, "): ", GetLastError());
         return false;
      }
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(InpTakeProfit > 0) tp = price - InpTakeProfit * _Point;
      if(InpStopLoss  > 0) sl = price + InpStopLoss  * _Point;

      if(!g_trade.Sell(lot, _Symbol, price, sl, tp, comment))
      {
         Print("Sell failed (step=", g_step, "): ", GetLastError());
         return false;
      }
   }

   Print("Trade opened: dir=", direction, " lot=", DoubleToString(lot, 2),
         " step=", g_step, " price=", DoubleToString(price, _Digits));
   return true;
}

//+------------------------------------------------------------------+
//| Add next Martingale level if price moved InpMartingaleGap points |
//+------------------------------------------------------------------+
void CheckMartingale()
{
   if(g_step >= InpMaxSteps) return;
   if(GetUnrealizedPnL() >= 0) return; // Only add when losing

   bool shouldAdd = false;

   if(g_direction == 1)
   {
      double entry  = GetFirstPositionPrice(POSITION_TYPE_BUY);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(entry > 0 && (entry - bid) >= InpMartingaleGap * _Point)
         shouldAdd = true;
   }
   else if(g_direction == -1)
   {
      double entry = GetFirstPositionPrice(POSITION_TYPE_SELL);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(entry > 0 && (ask - entry) >= InpMartingaleGap * _Point)
         shouldAdd = true;
   }

   if(shouldAdd)
   {
      g_step++;
      g_nextLot = NormalizeLot(InpInitialLot * MathPow(InpLotMultiplier, g_step));
      if(g_nextLot > InpMaxLot) g_nextLot = InpMaxLot;

      OpenTrade(g_direction, g_nextLot);
      Print("Martingale step ", g_step, " | new lot: ", DoubleToString(g_nextLot, 2));
   }
}

//+------------------------------------------------------------------+
//| Open/close the hedge position based on equity drawdown           |
//+------------------------------------------------------------------+
void ManageHedge()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return;

   double drawdownPct = (balance - equity) / balance * 100.0;

   //--- Open hedge when drawdown threshold is breached
   if(!g_hedgeActive && drawdownPct >= InpHedgeDrawdown && CountPositions(-1) > 0)
   {
      int    hedgeDir = (g_direction == 1) ? -1 : 1;
      double hedgeLot = NormalizeLot(GetTotalLots() * InpHedgeLotFactor);
      if(hedgeLot <= 0) return;

      double price, tp = 0.0;
      string comment = InpComment + "_HEDGE" + (hedgeDir == 1 ? "_B" : "_S");

      if(hedgeDir == 1)
      {
         price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(InpHedgeTP > 0) tp = price + InpHedgeTP * _Point;
         if(!g_trade.Buy(hedgeLot, _Symbol, price, 0, tp, comment)) return;
      }
      else
      {
         price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(InpHedgeTP > 0) tp = price - InpHedgeTP * _Point;
         if(!g_trade.Sell(hedgeLot, _Symbol, price, 0, tp, comment)) return;
      }

      g_hedgeActive = true;
      g_hedgeTicket = FindPositionByComment(comment);
      Print("Hedge opened: dir=", hedgeDir, " lot=", DoubleToString(hedgeLot, 2),
            " drawdown=", DoubleToString(drawdownPct, 2), "%");
   }

   //--- Close hedge when drawdown recovers to half the trigger level
   if(g_hedgeActive)
   {
      double hedgePnL = GetPositionPnLByTicket(g_hedgeTicket);
      if(hedgePnL > 0 && drawdownPct < InpHedgeDrawdown / 2.0)
      {
         if(g_pos.SelectByTicket(g_hedgeTicket))
         {
            g_trade.PositionClose(g_hedgeTicket);
            g_hedgeActive = false;
            g_hedgeTicket = 0;
            Print("Hedge closed. Drawdown recovered to ", DoubleToString(drawdownPct, 2), "%");
         }
         else
         {
            //--- Position no longer exists (may have hit TP)
            g_hedgeActive = false;
            g_hedgeTicket = 0;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all EA positions on _Symbol                                 |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
      {
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == InpMagicNumber)
            g_trade.PositionClose(g_pos.Ticket());
      }
   }
   g_hedgeActive = false;
   g_hedgeTicket = 0;
}

//+------------------------------------------------------------------+
//| Reset Martingale state (call when all positions are closed)       |
//+------------------------------------------------------------------+
void ResetState()
{
   g_step        = 0;
   g_direction   = 0;
   g_nextLot     = InpInitialLot;
   g_hedgeActive = false;
   g_hedgeTicket = 0;
}

//+------------------------------------------------------------------+
//| Count EA positions on _Symbol; type=-1 means count all           |
//+------------------------------------------------------------------+
int CountPositions(int type)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol() == _Symbol &&
         g_pos.Magic()  == InpMagicNumber)
      {
         if(type == -1 || (int)g_pos.PositionType() == type)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Sum unrealized P&L (profit + swap) for all EA positions           |
//+------------------------------------------------------------------+
double GetUnrealizedPnL()
{
   double pnl = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol() == _Symbol &&
         g_pos.Magic()  == InpMagicNumber)
         pnl += g_pos.Profit() + g_pos.Swap();
   }
   return pnl;
}

//+------------------------------------------------------------------+
//| Sum total lots for all EA positions on _Symbol                    |
//+------------------------------------------------------------------+
double GetTotalLots()
{
   double lots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol() == _Symbol &&
         g_pos.Magic()  == InpMagicNumber)
         lots += g_pos.Volume();
   }
   return lots;
}

//+------------------------------------------------------------------+
//| Return P&L of one specific position by ticket (0 if not found)   |
//+------------------------------------------------------------------+
double GetPositionPnLByTicket(ulong ticket)
{
   if(ticket == 0) return 0.0;
   if(g_pos.SelectByTicket(ticket))
      return g_pos.Profit() + g_pos.Swap();
   return 0.0;
}

//+------------------------------------------------------------------+
//| Return open price of the earliest position of the given type      |
//+------------------------------------------------------------------+
double GetFirstPositionPrice(ENUM_POSITION_TYPE type)
{
   double   price    = 0.0;
   datetime earliest = D'2037.12.31 00:00:00';

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol()       == _Symbol &&
         g_pos.Magic()        == InpMagicNumber &&
         g_pos.PositionType() == type)
      {
         if(g_pos.Time() < earliest)
         {
            earliest = g_pos.Time();
            price    = g_pos.PriceOpen();
         }
      }
   }
   return price;
}

//+------------------------------------------------------------------+
//| Round lot to broker's volume step and clamp to allowed range      |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, MathMin(maxLot, InpMaxLot));
   return lot;
}

//+------------------------------------------------------------------+
//| Returns true only on the first tick of a new bar                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime s_lastBar = 0;
   datetime currentBar = iTime(_Symbol, InpTimeframe, 0);
   if(currentBar != s_lastBar)
   {
      s_lastBar = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find an EA position on _Symbol that matches a given comment       |
//+------------------------------------------------------------------+
ulong FindPositionByComment(const string comment)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_pos.SelectByIndex(i) &&
         g_pos.Symbol()  == _Symbol &&
         g_pos.Magic()   == InpMagicNumber &&
         g_pos.Comment() == comment)
         return g_pos.Ticket();
   }
   return 0;
}
//+------------------------------------------------------------------+
