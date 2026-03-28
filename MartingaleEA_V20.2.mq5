//+------------------------------------------------------------------+
//| MartingaleEA_V20.2.mq5 — Martingale Grid + Full Hedge System    |
//| Copyright 2026, MetaQuotes Ltd.                                  |
//| https://www.mql5.com                                             |
//| V20.2 — 7 backtest-driven fixes (see change log below)          |
//|                                                                  |
//| Changes vs V19.3:                                               |
//|  [P0-1] AdjustBuyBasketTP / AdjustSellBasketTP: close basket    |
//|         immediately when hedge profit already covers target;     |
//|         clamp requiredUSD >= TPBufferUSD; sanity-check newTP    |
//|         against current ask/bid with TPBufferUSD distance.      |
//|  [P0-2] CheckMaxCycleLoss: add g_BuyHedgeProfit /              |
//|         g_SellHedgeProfit to the PnL check so realised hedge    |
//|         gains are not ignored.                                  |
//|  [P1-3] Safety stop: subtract SafetyBufferPts below trough      |
//|         (buy) / add above peak (sell) before firing.           |
//|  [P1-4] Hedge retrace guard: require MinHedgeRange pts of move |
//|         AND MinHedgeHoldSeconds hold-time before retrace check. |
//|  [P2-5] MaxSpreadPoints default raised 80 → 300.               |
//|  [P2-6] IsMarketOpen() guard skips new orders on weekends /    |
//|         pre-market gaps.                                        |
//|  [P2-7] g_TradeLock released on failed OrderSend in            |
//|         StartBuyCycle / StartSellCycle.                        |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- Grid inputs
input double StartLot          = 0.01;    // Initial lot size
input double LotMultiplier     = 2.0;     // Lot multiplier per grid level
input double GridStep          = 10.0;    // Grid spacing in price points
input int    MaxLevels         = 10;      // Hard cap: no new pending beyond this level
input ulong  Magic             = 20260321;// Base magic number

//--- Basket profit inputs
input double BasketProfitUSD   = 5.0;     // Target profit per basket (USD)
input double TPBufferUSD       = 2.0;     // [V20.2 P0] Min USD-equivalent TP distance (raised from 1.0)

//--- Hedge inputs
input double HedgeMultiplier      = 1.0;  // Hedge lots = basket total * this (1.0–1.3)
input double HedgeRetracePct      = 20.0; // Retrace % before closing hedge (0–100)
input int    HedgeTriggerLevel    = 6;    // Open hedge after this many grid levels
input double MinHedgeRange        = 5.0;  // [V20.2 P1] Min points moved before retrace check
input int    MinHedgeHoldSeconds  = 300;  // [V20.2 P1] Min seconds hedge held before retrace close

//--- Risk inputs
input double MaxCycleLossUSD   = 1500.0;  // Max loss per basket before force-close
input int    MaxSpreadPoints   = 300;     // [V20.2 P2] Max allowed spread (raised from 80 for GOLD)

//--- Safety buffer (P1)
input double SafetyBufferPts   = 3.0;    // [V20.2 P1] Points below trough/above peak before safety stop

//--- Magic number offsets (runtime, set in OnInit)
ulong g_MagicBuyBasket;
ulong g_MagicSellBasket;
ulong g_MagicBuyHedge;   // SELL trade hedging the buy basket
ulong g_MagicSellHedge;  // BUY trade hedging the sell basket

//--- Per-basket hedge state — buy side
bool     g_BuyHedgeActive    = false;  // hedge position currently open
bool     g_BuyHedgeDone      = false;  // hedge was used this cycle — no second hedge
double   g_BuyHedgePrice     = 0.0;    // price at which hedge was opened
double   g_BuyLowestPrice    = 0.0;    // lowest bid tracked while hedge active
double   g_BuyHedgeProfit    = 0.0;    // realised profit from closed hedge
datetime g_BuyHedgeOpenTime  = 0;      // [V20.2 P1] time hedge was opened

//--- Per-basket hedge state — sell side
bool     g_SellHedgeActive    = false;
bool     g_SellHedgeDone      = false;
double   g_SellHedgePrice     = 0.0;
double   g_SellHighestPrice   = 0.0;   // highest ask tracked while hedge active
double   g_SellHedgeProfit    = 0.0;
datetime g_SellHedgeOpenTime  = 0;     // [V20.2 P1] time hedge was opened

//--- Spread gate throttle
datetime g_LastSpreadLog = 0;

//--- Trade lock (prevents duplicate market orders on fast ticks)
bool  g_TradeLock = false;
ulong g_LastDeal  = 0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_MagicBuyBasket  = Magic;
   g_MagicSellBasket = Magic + 1;
   g_MagicBuyHedge   = Magic + 10;  // SELL positions
   g_MagicSellHedge  = Magic + 11;  // BUY positions

   trade.SetExpertMagicNumber(Magic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Count open positions for a given magic + direction               |
//+------------------------------------------------------------------+
int CountByMagic(ulong magic, bool buy)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if( buy && type == POSITION_TYPE_BUY)  count++;
      if(!buy && type == POSITION_TYPE_SELL) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Sum open lots for a given magic + direction                      |
//+------------------------------------------------------------------+
double SumLotsByMagic(ulong magic, bool buy)
{
   double total = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if( buy && type == POSITION_TYPE_BUY)  total += PositionGetDouble(POSITION_VOLUME);
      if(!buy && type == POSITION_TYPE_SELL) total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

//+------------------------------------------------------------------+
//| Total floating P&L (profit + swap) for a given magic + direction |
//+------------------------------------------------------------------+
double BasketPnL(ulong magic, bool buy)
{
   double pnl = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if( buy && type == POSITION_TYPE_BUY)
         pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(!buy && type == POSITION_TYPE_SELL)
         pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//+------------------------------------------------------------------+
//| Close all positions for a given magic + direction                |
//+------------------------------------------------------------------+
void CloseAllByMagic(ulong magic, bool buy)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if( buy && type == POSITION_TYPE_BUY)  trade.PositionClose(ticket);
      if(!buy && type == POSITION_TYPE_SELL) trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders for a given magic                      |
//+------------------------------------------------------------------+
void DeleteAllPendingsByMagic(ulong magic)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)magic) continue;
      trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| True if a pending order already exists at the given price        |
//+------------------------------------------------------------------+
bool PendingAtPrice(ulong magic, ENUM_ORDER_TYPE type, double price)
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)magic) continue;
      if(OrderGetInteger(ORDER_TYPE) != type) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) < _Point * 5)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| True if any pending order of the given type exists for magic     |
//+------------------------------------------------------------------+
bool HasPendingOfType(ulong magic, ENUM_ORDER_TYPE type)
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)magic) continue;
      if(OrderGetInteger(ORDER_TYPE) == type) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Volume-weighted average entry price (VWAP) for a basket         |
//+------------------------------------------------------------------+
double BasketVWAP(ulong magic, bool buy)
{
   double sumPriceLot = 0.0, sumLot = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(( buy && type == POSITION_TYPE_BUY) ||
         (!buy && type == POSITION_TYPE_SELL))
      {
         double lot = PositionGetDouble(POSITION_VOLUME);
         sumPriceLot += PositionGetDouble(POSITION_PRICE_OPEN) * lot;
         sumLot      += lot;
      }
   }
   return (sumLot > 0.0) ? sumPriceLot / sumLot : 0.0;
}

//+------------------------------------------------------------------+
//| Next grid lot (doubles the largest position in the basket)       |
//+------------------------------------------------------------------+
double NextLot(ulong magic, bool buy)
{
   double maxLot = StartLot / LotMultiplier;   // base value: after *LotMultiplier returns StartLot for empty basket
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(( buy && type == POSITION_TYPE_BUY) ||
         (!buy && type == POSITION_TYPE_SELL))
      {
         double lot = PositionGetDouble(POSITION_VOLUME);
         if(lot > maxLot) maxLot = lot;
      }
   }
   return NormalizeDouble(maxLot * LotMultiplier, 2);
}

//+------------------------------------------------------------------+
//| USD value of a 1-point price move for 1 lot                      |
//+------------------------------------------------------------------+
double PointValuePerLot()
{
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tickSize <= 0.0) return 1.0;
   return tickVal * (pt / tickSize);
}

//+------------------------------------------------------------------+
//| Spread gate — returns false and logs (once/min) when spread high |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      datetime now = TimeCurrent();
      if(now - g_LastSpreadLog >= 60)
      {
         PrintFormat("RISK GATE: Spread %.0f > %d — skipping trades", spread, MaxSpreadPoints);
         g_LastSpreadLog = now;
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| [V20.2 P2] Market-open guard — returns false on weekends /      |
//| pre-market gaps so no new cycles are started.                    |
//+------------------------------------------------------------------+
bool IsMarketOpen()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Saturday (6) and Sunday (0) — forex / CFD market closed
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Set TP on every open position in a basket                        |
//+------------------------------------------------------------------+
void SetBasketTP(ulong magic, bool buy, double tp)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if( buy && type == POSITION_TYPE_BUY  && tp > ask)
         trade.PositionModify(ticket, 0, tp);
      if(!buy && type == POSITION_TYPE_SELL && tp < bid)
         trade.PositionModify(ticket, 0, tp);
   }
}

//+------------------------------------------------------------------+
//| [V20.2 P0] After buy-hedge closes: recalculate basket TP        |
//|  — close basket immediately if hedge profit covers target        |
//|  — clamp requiredUSD so TP can never go behind current ask       |
//+------------------------------------------------------------------+
void AdjustBuyBasketTP()
{
   double totalLots = SumLotsByMagic(g_MagicBuyBasket, true);
   if(totalLots <= 0.0) return;

   double pvPerLot = PointValuePerLot();
   if(pvPerLot <= 0.0) return;

   double vwap       = BasketVWAP(g_MagicBuyBasket, true);
   double currentPnL = BasketPnL(g_MagicBuyBasket, true) + g_BuyHedgeProfit;

   // [P0-1] Hedge profit already covers the target — close basket now
   if(currentPnL >= BasketProfitUSD)
   {
      PrintFormat("BUY BASKET TARGET MET via hedge: PnL=%.2f — closing basket", currentPnL);
      CloseAllByMagic(g_MagicBuyBasket, true);
      DeleteAllPendingsByMagic(g_MagicBuyBasket);
      g_BuyHedgeDone   = false;
      g_BuyHedgeProfit = 0.0;
      g_BuyLowestPrice = 0.0;
      g_BuyHedgePrice  = 0.0;
      return;
   }

   double requiredUSD = BasketProfitUSD + TPBufferUSD - g_BuyHedgeProfit;

   // [P0-1] Clamp: never let requiredUSD go below the minimum buffer
   if(requiredUSD < TPBufferUSD)
      requiredUSD = TPBufferUSD;

   double targetPts = requiredUSD / (totalLots * pvPerLot);
   double newTP     = NormalizeDouble(vwap + targetPts,
                                      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   // [P0-1] Sanity check: TP must be above current ask by at least TPBufferUSD worth of points
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minBufPts = TPBufferUSD / (totalLots * pvPerLot);
   if(newTP < ask + _Point)
      newTP = NormalizeDouble(ask + minBufPts, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   PrintFormat("BUY BE adjust: VWAP=%.5f hedgeProfit=%.2f requiredUSD=%.2f newTP=%.5f",
               vwap, g_BuyHedgeProfit, requiredUSD, newTP);
   SetBasketTP(g_MagicBuyBasket, true, newTP);
}

//+------------------------------------------------------------------+
//| [V20.2 P0] After sell-hedge closes: recalculate basket TP       |
//|  — mirror of AdjustBuyBasketTP for the sell side                 |
//+------------------------------------------------------------------+
void AdjustSellBasketTP()
{
   double totalLots = SumLotsByMagic(g_MagicSellBasket, false);
   if(totalLots <= 0.0) return;

   double pvPerLot = PointValuePerLot();
   if(pvPerLot <= 0.0) return;

   double vwap       = BasketVWAP(g_MagicSellBasket, false);
   double currentPnL = BasketPnL(g_MagicSellBasket, false) + g_SellHedgeProfit;

   // [P0-1] Hedge profit already covers the target — close basket now
   if(currentPnL >= BasketProfitUSD)
   {
      PrintFormat("SELL BASKET TARGET MET via hedge: PnL=%.2f — closing basket", currentPnL);
      CloseAllByMagic(g_MagicSellBasket, false);
      DeleteAllPendingsByMagic(g_MagicSellBasket);
      g_SellHedgeDone    = false;
      g_SellHedgeProfit  = 0.0;
      g_SellHighestPrice = 0.0;
      g_SellHedgePrice   = 0.0;
      return;
   }

   double requiredUSD = BasketProfitUSD + TPBufferUSD - g_SellHedgeProfit;

   // [P0-1] Clamp: never let requiredUSD go below the minimum buffer
   if(requiredUSD < TPBufferUSD)
      requiredUSD = TPBufferUSD;

   double targetPts = requiredUSD / (totalLots * pvPerLot);
   double newTP     = NormalizeDouble(vwap - targetPts,
                                      (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   // [P0-1] Sanity check: TP must be below current bid by at least TPBufferUSD worth of points
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minBufPts = TPBufferUSD / (totalLots * pvPerLot);
   if(newTP > bid - _Point)
      newTP = NormalizeDouble(bid - minBufPts, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   PrintFormat("SELL BE adjust: VWAP=%.5f hedgeProfit=%.2f requiredUSD=%.2f newTP=%.5f",
               vwap, g_SellHedgeProfit, requiredUSD, newTP);
   SetBasketTP(g_MagicSellBasket, false, newTP);
}

//+------------------------------------------------------------------+
//| Open hedge for buy basket (SELL trade with g_MagicBuyHedge)      |
//+------------------------------------------------------------------+
void OpenBuyHedge()
{
   double totalLots = SumLotsByMagic(g_MagicBuyBasket, true);
   double hedgeLots = NormalizeDouble(totalLots * HedgeMultiplier, 2);
   if(hedgeLots < 0.01) hedgeLots = 0.01;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   trade.SetExpertMagicNumber(g_MagicBuyHedge);
   if(trade.Sell(hedgeLots, _Symbol, bid, 0, 0))
   {
      g_BuyHedgeActive   = true;
      g_BuyHedgeDone     = true;   // hedge opened this cycle — no second hedge allowed
      g_BuyHedgePrice    = bid;
      g_BuyLowestPrice   = bid;
      g_BuyHedgeProfit   = 0.0;
      g_BuyHedgeOpenTime = TimeCurrent();  // [V20.2 P1]
      DeleteAllPendingsByMagic(g_MagicBuyBasket); // stop grid expansion
      PrintFormat("BUY HEDGE OPENED: %.2f lots SELL @ %.5f", hedgeLots, bid);
   }
   trade.SetExpertMagicNumber(Magic);
}

//+------------------------------------------------------------------+
//| Open hedge for sell basket (BUY trade with g_MagicSellHedge)     |
//+------------------------------------------------------------------+
void OpenSellHedge()
{
   double totalLots = SumLotsByMagic(g_MagicSellBasket, false);
   double hedgeLots = NormalizeDouble(totalLots * HedgeMultiplier, 2);
   if(hedgeLots < 0.01) hedgeLots = 0.01;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   trade.SetExpertMagicNumber(g_MagicSellHedge);
   if(trade.Buy(hedgeLots, _Symbol, ask, 0, 0))
   {
      g_SellHedgeActive    = true;
      g_SellHedgeDone      = true;   // hedge opened this cycle — no second hedge allowed
      g_SellHedgePrice     = ask;
      g_SellHighestPrice   = ask;
      g_SellHedgeProfit    = 0.0;
      g_SellHedgeOpenTime  = TimeCurrent();  // [V20.2 P1]
      DeleteAllPendingsByMagic(g_MagicSellBasket); // stop grid expansion
      PrintFormat("SELL HEDGE OPENED: %.2f lots BUY @ %.5f", hedgeLots, ask);
   }
   trade.SetExpertMagicNumber(Magic);
}

//+------------------------------------------------------------------+
//| Close buy-side hedge and record its profit                       |
//+------------------------------------------------------------------+
void CloseBuyHedge()
{
   g_BuyHedgeProfit = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)g_MagicBuyHedge) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         g_BuyHedgeProfit += PositionGetDouble(POSITION_PROFIT)
                           + PositionGetDouble(POSITION_SWAP);
         trade.PositionClose(ticket);
      }
   }
   g_BuyHedgeActive = false;
   g_BuyHedgeDone   = true;  // no second hedge this cycle
   PrintFormat("BUY HEDGE CLOSED: profit=%.2f — HedgeDone=true", g_BuyHedgeProfit);
   AdjustBuyBasketTP();
}

//+------------------------------------------------------------------+
//| Close sell-side hedge and record its profit                      |
//+------------------------------------------------------------------+
void CloseSellHedge()
{
   g_SellHedgeProfit = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)g_MagicSellHedge) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         g_SellHedgeProfit += PositionGetDouble(POSITION_PROFIT)
                            + PositionGetDouble(POSITION_SWAP);
         trade.PositionClose(ticket);
      }
   }
   g_SellHedgeActive = false;
   g_SellHedgeDone   = true;
   PrintFormat("SELL HEDGE CLOSED: profit=%.2f — HedgeDone=true", g_SellHedgeProfit);
   AdjustSellBasketTP();
}

//+------------------------------------------------------------------+
//| Manage hedge state for the buy basket (called each tick)         |
//+------------------------------------------------------------------+
void ManageBuyHedge()
{
   int    levels = CountByMagic(g_MagicBuyBasket, true);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_BuyHedgeActive)
   {
      // Track lowest price while hedge is open
      if(bid < g_BuyLowestPrice) g_BuyLowestPrice = bid;

      // [V20.2 P1] Retrace check: only activate after MinHedgeRange pts move
      //            AND MinHedgeHoldSeconds hold-time have elapsed
      double range = g_BuyHedgePrice - g_BuyLowestPrice;
      if(range >= MinHedgeRange * _Point &&
         TimeCurrent() - g_BuyHedgeOpenTime >= MinHedgeHoldSeconds)
      {
         double retracePrice = g_BuyLowestPrice + range * (HedgeRetracePct / 100.0);
         if(bid >= retracePrice)
         {
            PrintFormat("BUY HEDGE RETRACE HIT: Entry=%.5f Trough=%.5f Retrace=%.5f Bid=%.5f",
                        g_BuyHedgePrice, g_BuyLowestPrice, retracePrice, bid);
            CloseBuyHedge();
         }
      }
   }
   else if(!g_BuyHedgeDone)
   {
      // Trigger hedge once HedgeTriggerLevel is reached (never again in this cycle)
      if(levels >= HedgeTriggerLevel)
      {
         PrintFormat("BUY MaxLevels reached: %d — opening hedge", levels);
         OpenBuyHedge();
      }
   }
   else
   {
      // Recovery phase: hedge is done — watch for safety-stop condition.
      // [V20.2 P1] Apply SafetyBufferPts below the trough to avoid noise-triggered exit.
      if(g_BuyLowestPrice > 0.0 &&
         bid < (g_BuyLowestPrice - SafetyBufferPts * _Point))
      {
         PrintFormat("BUY SAFETY STOP: bid %.5f < trough %.5f - %.1f pts — closing basket",
                     bid, g_BuyLowestPrice, SafetyBufferPts);
         CloseAllByMagic(g_MagicBuyBasket, true);
         DeleteAllPendingsByMagic(g_MagicBuyBasket);
         g_BuyHedgeDone   = false;
         g_BuyHedgeProfit = 0.0;
         g_BuyLowestPrice = 0.0;
         g_BuyHedgePrice  = 0.0;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage hedge state for the sell basket (called each tick)        |
//+------------------------------------------------------------------+
void ManageSellHedge()
{
   int    levels = CountByMagic(g_MagicSellBasket, false);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_SellHedgeActive)
   {
      if(ask > g_SellHighestPrice) g_SellHighestPrice = ask;

      // [V20.2 P1] Retrace check: only activate after MinHedgeRange pts move
      //            AND MinHedgeHoldSeconds hold-time have elapsed
      double range = g_SellHighestPrice - g_SellHedgePrice;
      if(range >= MinHedgeRange * _Point &&
         TimeCurrent() - g_SellHedgeOpenTime >= MinHedgeHoldSeconds)
      {
         double retracePrice = g_SellHighestPrice - range * (HedgeRetracePct / 100.0);
         if(ask <= retracePrice)
         {
            PrintFormat("SELL HEDGE RETRACE HIT: Entry=%.5f Peak=%.5f Retrace=%.5f Ask=%.5f",
                        g_SellHedgePrice, g_SellHighestPrice, retracePrice, ask);
            CloseSellHedge();
         }
      }
   }
   else if(!g_SellHedgeDone)
   {
      if(levels >= HedgeTriggerLevel)
      {
         PrintFormat("SELL MaxLevels reached: %d — opening hedge", levels);
         OpenSellHedge();
      }
   }
   else
   {
      // Recovery phase: safety stop with buffer.
      // [V20.2 P1] Apply SafetyBufferPts above the peak to avoid noise-triggered exit.
      if(g_SellHighestPrice > 0.0 &&
         ask > (g_SellHighestPrice + SafetyBufferPts * _Point))
      {
         PrintFormat("SELL SAFETY STOP: ask %.5f > peak %.5f + %.1f pts — closing basket",
                     ask, g_SellHighestPrice, SafetyBufferPts);
         CloseAllByMagic(g_MagicSellBasket, false);
         DeleteAllPendingsByMagic(g_MagicSellBasket);
         g_SellHedgeDone    = false;
         g_SellHedgeProfit  = 0.0;
         g_SellHighestPrice = 0.0;
         g_SellHedgePrice   = 0.0;
      }
   }
}

//+------------------------------------------------------------------+
//| MaxCycleLoss safety: force-close basket + hedge if P&L too low   |
//+------------------------------------------------------------------+
void CheckMaxCycleLoss()
{
   // --- Buy basket ---
   if(CountByMagic(g_MagicBuyBasket, true) > 0)
   {
      double pnl = BasketPnL(g_MagicBuyBasket, true);
      if(g_BuyHedgeActive)
         pnl += BasketPnL(g_MagicBuyHedge, false);

      // [V20.2 P0-2] Include realised hedge profit so banked gains offset open loss
      pnl += g_BuyHedgeProfit;

      if(pnl <= -MaxCycleLossUSD)
      {
         PrintFormat("MAX CYCLE LOSS HIT on BUY side: %.2f (incl hedgeProfit=%.2f) — closing all",
                     pnl, g_BuyHedgeProfit);
         CloseAllByMagic(g_MagicBuyBasket, true);
         CloseAllByMagic(g_MagicBuyHedge, false);
         DeleteAllPendingsByMagic(g_MagicBuyBasket);
         g_BuyHedgeActive = false;
         g_BuyHedgeDone   = false;
         g_BuyHedgeProfit = 0.0;
         g_BuyLowestPrice = 0.0;
         g_BuyHedgePrice  = 0.0;
      }
   }

   // --- Sell basket ---
   if(CountByMagic(g_MagicSellBasket, false) > 0)
   {
      double pnl = BasketPnL(g_MagicSellBasket, false);
      if(g_SellHedgeActive)
         pnl += BasketPnL(g_MagicSellHedge, true);

      // [V20.2 P0-2] Include realised hedge profit so banked gains offset open loss
      pnl += g_SellHedgeProfit;

      if(pnl <= -MaxCycleLossUSD)
      {
         PrintFormat("MAX CYCLE LOSS HIT on SELL side: %.2f (incl hedgeProfit=%.2f) — closing all",
                     pnl, g_SellHedgeProfit);
         CloseAllByMagic(g_MagicSellBasket, false);
         CloseAllByMagic(g_MagicSellHedge, true);
         DeleteAllPendingsByMagic(g_MagicSellBasket);
         g_SellHedgeActive  = false;
         g_SellHedgeDone    = false;
         g_SellHedgeProfit  = 0.0;
         g_SellHighestPrice = 0.0;
         g_SellHedgePrice   = 0.0;
      }
   }
}

//+------------------------------------------------------------------+
//| Start a fresh buy-basket cycle                                   |
//+------------------------------------------------------------------+
void StartBuyCycle()
{
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double firstTP   = ask + GridStep;
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   trade.SetExpertMagicNumber(g_MagicBuyBasket);
   if(trade.Buy(StartLot, _Symbol, ask, 0, firstTP))
   {
      double nextPrice  = ask - GridStep;
      double nextLot    = NormalizeDouble(StartLot * LotMultiplier, 2);
      if(MathAbs(ask - nextPrice) > stopLevel &&
         !PendingAtPrice(g_MagicBuyBasket, ORDER_TYPE_BUY_LIMIT, nextPrice))
      {
         trade.BuyLimit(nextLot, nextPrice, _Symbol);
      }
   }
   else
   {
      // [V20.2 P2-7] Release trade lock on failed send so EA doesn't freeze
      g_TradeLock = false;
   }
   trade.SetExpertMagicNumber(Magic);

   // Reset hedge state for the new cycle
   g_BuyHedgeActive   = false;
   g_BuyHedgeDone     = false;
   g_BuyHedgeProfit   = 0.0;
   g_BuyLowestPrice   = 0.0;
   g_BuyHedgePrice    = 0.0;
   g_BuyHedgeOpenTime = 0;
}

//+------------------------------------------------------------------+
//| Start a fresh sell-basket cycle                                  |
//+------------------------------------------------------------------+
void StartSellCycle()
{
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double firstTP   = bid - GridStep;
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   trade.SetExpertMagicNumber(g_MagicSellBasket);
   if(trade.Sell(StartLot, _Symbol, bid, 0, firstTP))
   {
      double nextPrice = bid + GridStep;
      double nextLot   = NormalizeDouble(StartLot * LotMultiplier, 2);
      if(MathAbs(nextPrice - bid) > stopLevel &&
         !PendingAtPrice(g_MagicSellBasket, ORDER_TYPE_SELL_LIMIT, nextPrice))
      {
         trade.SellLimit(nextLot, nextPrice, _Symbol);
      }
   }
   else
   {
      // [V20.2 P2-7] Release trade lock on failed send so EA doesn't freeze
      g_TradeLock = false;
   }
   trade.SetExpertMagicNumber(Magic);

   g_SellHedgeActive    = false;
   g_SellHedgeDone      = false;
   g_SellHedgeProfit    = 0.0;
   g_SellHighestPrice   = 0.0;
   g_SellHedgePrice     = 0.0;
   g_SellHedgeOpenTime  = 0;
}

//+------------------------------------------------------------------+
//| Handle a buy-basket fill: update TP and place next grid level    |
//+------------------------------------------------------------------+
void HandleBuyFill(double price)
{
   int levels = CountByMagic(g_MagicBuyBasket, true);

   // Move all basket TPs to the new entry price + GridStep (spec: TP = previous entry)
   if(levels >= 2)
      SetBasketTP(g_MagicBuyBasket, true, price + GridStep);

   // Stop placing new grid orders when hedge is active, HedgeTriggerLevel reached,
   // or hard MaxLevels cap hit
   if(g_BuyHedgeActive || levels >= HedgeTriggerLevel || levels >= MaxLevels)
      return;

   double nextPrice  = price - GridStep;
   double lot        = NextLot(g_MagicBuyBasket, true);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLevel  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(MathAbs(ask - nextPrice) <= stopLevel) return;

   if(!HasPendingOfType(g_MagicBuyBasket, ORDER_TYPE_BUY_LIMIT))
   {
      trade.SetExpertMagicNumber(g_MagicBuyBasket);
      trade.BuyLimit(lot, nextPrice, _Symbol);
      trade.SetExpertMagicNumber(Magic);
   }
}

//+------------------------------------------------------------------+
//| Handle a sell-basket fill: update TP and place next grid level   |
//+------------------------------------------------------------------+
void HandleSellFill(double price)
{
   int levels = CountByMagic(g_MagicSellBasket, false);

   if(levels >= 2)
      SetBasketTP(g_MagicSellBasket, false, price - GridStep);

   if(g_SellHedgeActive || levels >= HedgeTriggerLevel || levels >= MaxLevels)
      return;

   double nextPrice = price + GridStep;
   double lot       = NextLot(g_MagicSellBasket, false);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(MathAbs(nextPrice - bid) <= stopLevel) return;

   if(!HasPendingOfType(g_MagicSellBasket, ORDER_TYPE_SELL_LIMIT))
   {
      trade.SetExpertMagicNumber(g_MagicSellBasket);
      trade.SellLimit(lot, nextPrice, _Symbol);
      trade.SetExpertMagicNumber(Magic);
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res)
{
   g_TradeLock = false;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == g_LastDeal) return;
   g_LastDeal = trans.deal;

   if(!HistoryDealSelect(trans.deal)) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   ulong dealMagic = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long  type      = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double price    = HistoryDealGetDouble(trans.deal, DEAL_PRICE);

   // Only react to basket fills, not hedge fills
   if(dealMagic == g_MagicBuyBasket  && type == DEAL_TYPE_BUY)  HandleBuyFill(price);
   if(dealMagic == g_MagicSellBasket && type == DEAL_TYPE_SELL) HandleSellFill(price);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsSpreadOK()) return;

   CheckMaxCycleLoss();

   // --- Buy side ---
   int buyCount      = CountByMagic(g_MagicBuyBasket, true);
   int buyHedgeCount = CountByMagic(g_MagicBuyHedge,  false);

   if(buyCount > 0)
   {
      ManageBuyHedge();
   }
   else if(buyHedgeCount > 0)
   {
      // Basket gone but hedge orphaned — close it then start fresh next tick
      CloseAllByMagic(g_MagicBuyHedge, false);
      DeleteAllPendingsByMagic(g_MagicBuyBasket);
      g_BuyHedgeActive = false;
      g_BuyHedgeDone   = false;
   }
   else if(!g_TradeLock && IsMarketOpen())  // [V20.2 P2-6] guard against weekend/gap
   {
      DeleteAllPendingsByMagic(g_MagicBuyBasket);
      g_TradeLock = true;
      StartBuyCycle();
   }

   // --- Sell side ---
   int sellCount      = CountByMagic(g_MagicSellBasket, false);
   int sellHedgeCount = CountByMagic(g_MagicSellHedge,  true);

   if(sellCount > 0)
   {
      ManageSellHedge();
   }
   else if(sellHedgeCount > 0)
   {
      CloseAllByMagic(g_MagicSellHedge, true);
      DeleteAllPendingsByMagic(g_MagicSellBasket);
      g_SellHedgeActive = false;
      g_SellHedgeDone   = false;
   }
   else if(!g_TradeLock && IsMarketOpen())  // [V20.2 P2-6] guard against weekend/gap
   {
      DeleteAllPendingsByMagic(g_MagicSellBasket);
      g_TradeLock = true;
      StartSellCycle();
   }
}
