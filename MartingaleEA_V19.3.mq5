//+------------------------------------------------------------------+
//|                                           MartingaleEA_V19.3.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

input double StartLot = 0.01;
input double LotMultiplier = 2;
input double BasketProfitUSD = 5.0;   // minimum basket profit
input double TPBufferUSD     = 1.0;   // safety buffer above breakeven
input double GridStep = 10.0;
input int MaxLevels = 10;
input ulong Magic = 20260321;

bool TradeLock=false;

ulong lastDeal=0;

//-------------------------------------------------------------

int CountSide(bool buy)
{
   int count=0;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=Magic)
         continue;

      int type=(int)PositionGetInteger(POSITION_TYPE);

      if(buy && type==POSITION_TYPE_BUY)
         count++;

      if(!buy && type==POSITION_TYPE_SELL)
         count++;
   }

   return count;
}

//-------------------------------------------------------------

double NextLot(bool buy)
{
   double maxLot=StartLot;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=Magic)
         continue;

      bool isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);

      if(isBuy==buy)
      {
         double lot=PositionGetDouble(POSITION_VOLUME);

         if(lot>maxLot)
            maxLot=lot;
      }
   }

   return NormalizeDouble(maxLot*2,2);
}

//-------------------------------------------------------------
bool PendingAtPrice(ENUM_ORDER_TYPE type,double price)
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetInteger(ORDER_MAGIC)!=Magic)
         continue;

      if(OrderGetInteger(ORDER_TYPE)!=type)
         continue;

      double p=OrderGetDouble(ORDER_PRICE_OPEN);

      if(MathAbs(p-price)<_Point*5)
         return true;
   }

   return false;
   }
   
bool PendingExists(ENUM_ORDER_TYPE type,double price)
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetInteger(ORDER_TYPE)!=type)
         continue;

      double p=OrderGetDouble(ORDER_PRICE_OPEN);

      if(MathAbs(p-price) < _Point*10)
         return true;
   }

   return false;
}
//-------------------------------------------------------------

  ;void DeletePendings(ENUM_ORDER_TYPE type)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetInteger(ORDER_MAGIC)!=Magic)
         continue;

      if(OrderGetInteger(ORDER_TYPE)==type)
         trade.OrderDelete(ticket);
   }
}

//-------------------------------------------------------------

void MoveBasketTP(bool buy,double tp)
{
   if(CountSide(buy)<2)
      return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=Magic)
         continue;

      int type=(int)PositionGetInteger(POSITION_TYPE);

      if(buy && type==POSITION_TYPE_BUY && tp>bid)
         trade.PositionModify(ticket,0,tp);

      if(!buy && type==POSITION_TYPE_SELL && tp<ask)
         trade.PositionModify(ticket,0,tp);
   }
}

//-------------------------------------------------------------

void StartBuyCycle()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   trade.SetExpertMagicNumber(Magic);

   trade.Buy(StartLot,_Symbol,ask,0,ask+GridStep);

   double nextPrice = ask-GridStep;

if(!PendingExists(ORDER_TYPE_BUY_LIMIT,nextPrice))
   if(!TradeLock)
{
   if(!HasPendingType(ORDER_TYPE_BUY_LIMIT))
   trade.BuyLimit(NextLot(true),nextPrice,_Symbol);
   TradeLock=true;
}
}

//-------------------------------------------------------------

void StartSellCycle()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   trade.SetExpertMagicNumber(Magic);

   trade.Sell(StartLot,_Symbol,bid,0,bid-GridStep);

   double nextPrice = bid+GridStep;

if(!PendingExists(ORDER_TYPE_SELL_LIMIT,nextPrice))
   if(!TradeLock)
{
  if(!HasPendingType(ORDER_TYPE_SELL_LIMIT))
   trade.SellLimit(NextLot(false),nextPrice,_Symbol);
   TradeLock=true;
}
}

//-------------------------------------------------------------

void HandleBuyFill(double price)
{
   MoveBasketTP(true,price+GridStep);

   double nextPrice = price - GridStep;
   double lot       = NextLot(true);

 if(!PendingExists(ORDER_TYPE_BUY_LIMIT,nextPrice) && !TradeLock)
{
   if(!HasPendingType(ORDER_TYPE_BUY_LIMIT))
{
   if(!HasPendingType(ORDER_TYPE_BUY_LIMIT))
   trade.BuyLimit(lot,nextPrice,_Symbol);
}
   TradeLock=true;
}
}
//-------------------------------------------------------------

void HandleSellFill(double price)
{
   MoveBasketTP(false,price-GridStep);

   double nextPrice = price + GridStep;
   double lot       = NextLot(false);

   if(!PendingExists(ORDER_TYPE_SELL_LIMIT,nextPrice) && !TradeLock)
{
   if(!HasPendingType(ORDER_TYPE_SELL_LIMIT))
{
   if(!HasPendingType(ORDER_TYPE_SELL_LIMIT))
   trade.SellLimit(lot,nextPrice,_Symbol);
}
   TradeLock=true;
}
}

//-------------------------------------------------------------

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res)
{
   TradeLock=false;
   
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal==lastDeal)
      return;

   lastDeal=trans.deal;

   if(!HistoryDealSelect(trans.deal))
      return;
      
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_IN)
   return;
      
      if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_IN)
   return;

   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=Magic)
      return;

   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_IN)
      return;

   long type=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   double price=HistoryDealGetDouble(trans.deal,DEAL_PRICE);

   if(type==DEAL_TYPE_BUY)
      HandleBuyFill(price);

   if(type==DEAL_TYPE_SELL)
      HandleSellFill(price);
}

//-------------------------------------------------------------

bool BuyExists()
{
   return CountSide(true)>0;
}

bool SellExists()
{
   return CountSide(false)>0;
}

//-------------------------------------------------------------

bool HasPendingType(ENUM_ORDER_TYPE type)
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetInteger(ORDER_MAGIC)!=Magic)
         continue;

      if(OrderGetInteger(ORDER_TYPE)==type)
         return true;
   }

   return false;
}
void OnTick()
{
   if(!BuyExists())
   {
      DeletePendings(ORDER_TYPE_BUY_LIMIT);
      StartBuyCycle();
   }

   if(!SellExists())
   {
      DeletePendings(ORDER_TYPE_SELL_LIMIT);
      StartSellCycle();
   }
}

