#property strict
#property version   "3.6"


#include "CTradeSilent.mqh"

CTradeSilent trade;
CPositionInfo pos;

input group " 💫 Grid settings "
input double          InpRiskFactor    = 50;        // Risk Factor
input int             InpGridSteps     = 12;        // Grid steps per side

input group " 📊 ATR settings "
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_H2; // ATR Timeframe
input int             InpAtrPeriod     = 14;        // ATR Period

input group " 🏛️ Symbol settings "
input string          InpSymbols       = "EURUSD";  // Symbols to trade comma-seperated (AUDCAD,NZDCAD)

input group " ✨ Expert settings "
input bool            InpDrawChart     = true;      // Draw on chart (disable for faster testing)
input int             InpMagic         = 777123;    // Magic number



struct SymbolState
  {
   string            symbol;

   int               atrHandleMN;
   int               atrHandleD1;
   int               gBuyCount;
   int               gSellCount;
   double            gBuyLots;
   double            gSellLots;
   double            gBuyProfit;
   double            gSellProfit;
   double            gBuySwap;
   double            gSellSwap;
   double            gLowestBuy;
   double            gHighestBuy;
   double            gLowestSell;
   double            gHighestSell;
   double            gBuyAvgPrice;
   double            gSellAvgPrice;

   double            gSpreadSum;
   int               gSpreadCount;
   double            gSpreadAvg;
   datetime          gSpreadStartTime;

   double            gCommPerLot;
   datetime          gCommTime;
   bool              gCommValid;

   double            gTickSize;
   double            gTickValue;
   MqlTick           gTick;
   bool              gTickOk;

   double            gGridLots[64];
   int               gGridDepth;
   double            gGridBaseStep;
  };

SymbolState gStates[];

bool UpdateMarketData(SymbolState &S)
  {
   S.gTickOk = SymbolInfoTick(S.symbol, S.gTick);
   if(!S.gTickOk)
      return false;

   S.gTickSize  = SymbolInfoDouble(S.symbol, SYMBOL_TRADE_TICK_SIZE);
   S.gTickValue = SymbolInfoDouble(S.symbol, SYMBOL_TRADE_TICK_VALUE);
   return (S.gTickSize > 0.0 && S.gTickValue > 0.0);
  }

bool IsMarketOpen(const string symbol)
  {
   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   ENUM_DAY_OF_WEEK day = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   datetime timeToday = now % 86400;

   for(uint session = 0; session < 3; session++)
     {
      datetime from, to;
      if(!SymbolInfoSessionTrade(symbol, day, session, from, to))
         break;
      if(timeToday >= from && timeToday <= to)
         return true;
     }
   return false;
  }

bool IsMarketClosingSoon(const string symbol, const int bufferMinutes = 60)
  {
   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   int nowSec    = dt.hour * 3600 + dt.min * 60 + dt.sec;
   int bufferSec = bufferMinutes * 60;
   ENUM_DAY_OF_WEEK day = (ENUM_DAY_OF_WEEK)dt.day_of_week;

   int lastTo = -1;
   for(int s = 0; s < 3; s++)
     {
      datetime f, t;
      if(!SymbolInfoSessionTrade(symbol, day, s, f, t))
         break;
      lastTo = (int)t;
     }
   if(lastTo < 0)
      return false;

   int timeUntilClose = lastTo - nowSec;
   return (timeUntilClose <= bufferSec);
  }

void LogSpread(SymbolState &S, double spreadPercent)
  {
   datetime now = TimeCurrent();

   if(S.gSpreadStartTime == 0)
      S.gSpreadStartTime = now;

   if(now - S.gSpreadStartTime >= 86400)
     {
      S.gSpreadStartTime = now;
      S.gSpreadSum       = 0.0;
      S.gSpreadCount     = 0;
      S.gSpreadAvg       = 0.0;
     }

   S.gSpreadSum   += spreadPercent;
   S.gSpreadCount++;
   if(S.gSpreadCount > 0)
      S.gSpreadAvg = S.gSpreadSum / S.gSpreadCount;
  }

bool SpreadOK(SymbolState &S)
  {
   if(!S.gTickOk)
      return true;

   double price = S.gTick.ask;
   if(price <= 0.0)
      return true;

   double spreadPercent = ((S.gTick.ask - S.gTick.bid) / price) * 100.0;
   LogSpread(S, spreadPercent);

   if(S.gSpreadCount < 20)
      return true;

   return (spreadPercent <= S.gSpreadAvg);
  }

double NormalizeLot(double lot, const string symbol)
  {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;

   double steps = MathFloor(lot / stepLot);
   return NormalizeDouble(steps * stepLot, 8);
  }

double ClampLot(double lot, const string symbol)
  {
   return NormalizeLot(lot, symbol);
  }

bool GetMarginPerLot(const string symbol, int type, double price, double &marginPerLot)
  {
   marginPerLot = 0.0;
   ENUM_ORDER_TYPE ot = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(ot, symbol, 1.0, price, marginPerLot))
      return false;
   if(marginPerLot <= 0.0)
      marginPerLot = 1.0;
   return true;
  }

bool CheckMoneyForTrade(const string symbol, double lot, ENUM_ORDER_TYPE orderType, double commissionPerLot)
  {
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return false;

   double price = (orderType == ORDER_TYPE_BUY ? tick.ask : tick.bid);
   double margin = 0.0;
   if(!OrderCalcMargin(orderType, symbol, lot, price, margin))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double totalMargin = margin + commissionPerLot;
   return (totalMargin < freeMargin * 0.9);
  }

// Round-turn cost per lot.
//
// The old version read a SINGLE deal - the most recent one - and returned its
// commission per lot. That makes the answer depend on whether the last deal
// happened to be an entry or an exit: brokers that charge the whole round turn
// on entry report ~0 on the exit deal, so the cost read as either the full
// amount or nothing at all depending on timing. It also fell back to a made-up
// 1.0 per lot when no history existed, and rounded the result upward.
//
// Aggregating every commission and fee over the window and dividing by the
// volume that was OPENED gives the true round-turn cost per lot under either
// charging model, because each position contributes all of its deals' costs but
// its entry volume only once.
double GetNormalizedCommission(SymbolState &S)
  {
   datetime now = TimeTradeServer();
   if(S.gCommValid && (now - S.gCommTime) < 60)
      return S.gCommPerLot;

   double result = 0.0;

   datetime fromSrv = now - 30 * 24 * 60 * 60;
   if(HistorySelect(fromSrv, now))
     {
      int    dealsCount = HistoryDealsTotal();
      double costSum    = 0.0;
      double entryVol   = 0.0;

      for(int i = dealsCount - 1; i >= 0; i--)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;

         int type = (int)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;

         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != S.symbol)
            continue;

         // commission and fee are negative when charged
         costSum += -(HistoryDealGetDouble(dealTicket, DEAL_COMMISSION) +
                      HistoryDealGetDouble(dealTicket, DEAL_FEE));

         if((int)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
            entryVol += HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
        }

      if(entryVol > 0.0 && costSum > 0.0)
         result = costSum / entryVol;
     }

   S.gCommPerLot = result;
   S.gCommTime   = now;
   S.gCommValid  = true;
   return result;
  }

void ScanBaskets(SymbolState &S)
  {
   S.gBuyCount    = 0;
   S.gSellCount   = 0;
   S.gBuyLots     = 0.0;
   S.gSellLots    = 0.0;
   S.gBuyProfit   = 0.0;
   S.gSellProfit  = 0.0;
   S.gBuySwap     = 0.0;
   S.gSellSwap    = 0.0;
   S.gLowestBuy   = DBL_MAX;
   S.gHighestBuy  = -DBL_MAX;
   S.gLowestSell  = DBL_MAX;
   S.gHighestSell = -DBL_MAX;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket))
         continue;
      if(pos.Symbol() != S.symbol)
         continue;
      if(pos.Magic() != InpMagic)
         continue;

      double po  = pos.PriceOpen();
      double vol = pos.Volume();
      double prf = pos.Profit();
      double swp = pos.Swap();
      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         S.gBuyCount++;
         S.gBuyLots   += vol;
         S.gBuyProfit += prf;
         S.gBuySwap   += swp;
         if(po < S.gLowestBuy)
            S.gLowestBuy = po;
         if(po > S.gHighestBuy)
            S.gHighestBuy = po;
        }
      else
         if(pos.PositionType() == POSITION_TYPE_SELL)
           {
            S.gSellCount++;
            S.gSellLots   += vol;
            S.gSellProfit += prf;
            S.gSellSwap   += swp;
            if(po < S.gLowestSell)
               S.gLowestSell = po;
            if(po > S.gHighestSell)
               S.gHighestSell = po;
           }
     }
  }

void UpdateBasketAverages(SymbolState &S)
  {
   S.gBuyAvgPrice  = 0.0;
   S.gSellAvgPrice = 0.0;

   double buyWeighted  = 0.0;
   double sellWeighted = 0.0;
   S.gBuyLots  = 0.0;
   S.gSellLots = 0.0;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket))
         continue;
      if(pos.Symbol() != S.symbol)
         continue;
      if(pos.Magic() != InpMagic)
         continue;

      double lot  = pos.Volume();
      double open = pos.PriceOpen();

      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         S.gBuyLots    += lot;
         buyWeighted   += lot * open;
        }
      else
         if(pos.PositionType() == POSITION_TYPE_SELL)
           {
            S.gSellLots    += lot;
            sellWeighted   += lot * open;
           }
     }

   if(S.gBuyLots > 0.0)
      S.gBuyAvgPrice = buyWeighted / S.gBuyLots;
   if(S.gSellLots > 0.0)
      S.gSellAvgPrice = sellWeighted / S.gSellLots;
  }

double GetAverageATR(SymbolState &S, int bars)
  {
   if(S.atrHandleMN == INVALID_HANDLE)
      return 0.0;

   static double buf[1024];
   int count = MathMin(bars, 1024);
   if(CopyBuffer(S.atrHandleMN, 0, 0, count, buf) < count)
      return 0.0;

   double sum = 0.0;
   for(int i = 0; i < count; i++)
      sum += buf[i];

   return (count > 0 ? sum / count : 0.0);
  }
// Realised drawdown of the grid at a given scale, measured on the lots the
// broker will actually accept. Mirrors NormalizeLot with the symbol constants
// hoisted out, since the search below evaluates this many times per rebuild.
double GridDDAtScale(const double &rawLots[], int depth, double scale, double K,
                     double minLot, double maxLot, double stepLot, double commPerLot,
                     double &outLots[])
{
    double dd     = 0.0;
    double lotSum = 0.0;

    for(int i = 0; i < depth; i++)
    {
        double lot = rawLots[i] * scale;
        if(lot < minLot) lot = minLot;
        if(lot > maxLot) lot = maxLot;

        lot = NormalizeDouble(MathFloor(lot / stepLot) * stepLot, 8);

        outLots[i] = lot;
        dd     += lot * (depth - i);
        lotSum += lot;
    }

    // The trough is the price loss PLUS what it costs to have been there. The
    // model counted only price movement, so the real drawdown always exceeded
    // the budget by the round turn on the whole deployed grid.
    return dd * K + commPerLot * lotSum;
}

double BuildDDGrid(SymbolState &S, double baseStep)
{
    if(baseStep <= 0.0 || S.gTickSize <= 0.0 || S.gTickValue <= 0.0)
        return 0.0;

    int N = MathMax(1, MathMin(InpGridSteps, 64));

    bool haveLadder = (S.gGridDepth > 0 && S.gGridLots[0] > 0.0);
    bool flat       = (S.gBuyCount == 0 && S.gSellCount == 0);

    // A drawdown budget only means anything if the grid that gets DEPLOYED is
    // the grid that was measured. baseStep tracks the live ATR of the forming
    // bar, so it moves on nearly every tick; rebuilding whenever it moves
    // re-sizes the levels that have not been opened yet, halfway through a
    // cycle, against a balance that has also changed. The levels already open
    // were sized under one budget and the rest under another, so the measured
    // drawdown never described the real basket.
    //
    // Freeze the ladder for the life of a cycle and rebuild only when flat.
    if(haveLadder && (!flat || S.gGridBaseStep == baseStep))
        return S.gGridLots[0];

    double minLot     = SymbolInfoDouble(S.symbol, SYMBOL_VOLUME_MIN);
    double maxLot     = SymbolInfoDouble(S.symbol, SYMBOL_VOLUME_MAX);
    double stepLot    = SymbolInfoDouble(S.symbol, SYMBOL_VOLUME_STEP);
    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double commPerLot = GetNormalizedCommission(S);

    if(stepLot <= 0.0)
        stepLot = (minLot > 0.0 ? minLot : 0.01);

    // aggression factor: >1 = larger base lot, more profit, more DD.
    // At 1.0 the budget is exactly what InpRiskFactor says: at 2.0 a Risk
    // Factor of 50 quietly budgeted 100% of the balance, not 50%.
    double aggression = 1.0;

    double maxDD   = balance * (InpRiskFactor / 100.0) * aggression;
    double K       = (baseStep / S.gTickSize) * S.gTickValue;

    // Each level is sized from the drawdown it has to clear: one step of
    // retrace must bring the basket back to break-even.
    //
    // The old form was rawLots[i] = sum rawLots[k]*(i-k), which sized the new
    // level to cover the whole accumulated drawdown BY ITSELF. But a one-step
    // retrace pays every position in the basket, not just the one being added,
    // so the levels already open cover their own share. Ignoring that
    // over-sized every level, and the error compounded: break-even landed at
    // 0.618 steps instead of 1.0, and the ladder ran 584x more extreme by
    // level 24 to buy a recovery nobody asked for.
    //
    // Subtracting the open volume sizes the shortfall only, and lands the
    // basket exactly on break-even after one step at every depth.
    double rawLots[64];
    rawLots[0] = 1.0;

    for(int i = 1; i < N; i++)
    {
        double drawdown = 0.0;   // basket loss at this depth, in step-units
        double open     = 0.0;   // volume already working, which also recovers

        for(int k = 0; k < i; k++)
        {
            drawdown += rawLots[k] * (i - k);
            open     += rawLots[k];
        }

        double need = drawdown - open;
        rawLots[i] = (need > 1.0 ? need : 1.0);
    }

    // Scaling alone does not bound the drawdown. Every level whose scaled lot
    // lands below the broker minimum gets clamped UP to minLot, adding risk the
    // scale factor never accounted for - so the grid overshoots maxDD, worst on
    // small accounts where most levels clamp.
    //
    // Fix: keep the grid depth and search for the largest scale whose REALISED
    // drawdown fits. Depth is only reduced when even an all-minimum-lot grid
    // cannot fit, i.e. the account is genuinely too small for this step size.
    double lots[64];

    for(int depth = N; depth >= 1; depth--)
    {
        double rawDD = 0.0;
        for(int i = 0; i < depth; i++)
            rawDD += rawLots[i] * (depth - i);
        rawDD *= K;

        if(rawDD <= 0.0)
            continue;

        double hi = maxDD / rawDD;   // scale that would fit if nothing clamped

        if(GridDDAtScale(rawLots, depth, hi, K, minLot, maxLot, stepLot, commPerLot, lots) > maxDD)
        {
            // an all-minimum-lot grid is the cheapest this depth can be
            if(GridDDAtScale(rawLots, depth, 0.0, K, minLot, maxLot, stepLot, commPerLot, lots) > maxDD)
                continue;

            double lo = 0.0;
            for(int it = 0; it < 40; it++)
            {
                double mid = (lo + hi) * 0.5;
                if(GridDDAtScale(rawLots, depth, mid, K, minLot, maxLot, stepLot, commPerLot, lots) <= maxDD)
                    lo = mid;
                else
                    hi = mid;
            }
            GridDDAtScale(rawLots, depth, lo, K, minLot, maxLot, stepLot, commPerLot, lots);
        }

        S.gGridDepth    = depth;
        S.gGridBaseStep = baseStep;

        for(int i = 0; i < depth; i++)
            S.gGridLots[i] = NormalizeLot(lots[i], S.symbol);
        for(int i = depth; i < 64; i++)
            S.gGridLots[i] = 0.0;

        return S.gGridLots[0];
    }

    // Even a single minimum-lot position exceeds the budget: do not trade.
    S.gGridDepth    = 0;
    S.gGridBaseStep = baseStep;
    ArrayInitialize(S.gGridLots, 0.0);
    return 0.0;
}

// Drawdown of THIS symbol's basket, on the same basis the budget is expressed
// in: price loss, plus swap already charged, plus the round turn still to pay.
//
// The old body returned balance - equity, which took S and ignored it. That is
// the whole ACCOUNT's unrealized loss - every symbol, every magic number, any
// manual trade - and it is not a drawdown either: balance already absorbs
// realized losses, so it reads 0 on an account sitting far below its peak.
double GetBasketDrawdown(SymbolState &S)
{
   double floating = 0.0;
   double lots     = 0.0;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket))
         continue;
      if(pos.Symbol() != S.symbol)
         continue;
      if(pos.Magic() != InpMagic)
         continue;

      floating += pos.Profit() + pos.Swap();
      lots     += pos.Volume();
     }

   double net = floating - GetNormalizedCommission(S) * lots;
   return (net < 0.0 ? -net : 0.0);
}


double CalcBaseLotFromGrid(SymbolState &S, double baseStep)
  {
   return BuildDDGrid(S, baseStep);
  }

double CalcProjectedLot(SymbolState &S, int type, double levelPrice, double baseStep, double baseLot)
{
   if(S.gGridDepth <= 0)
      return 0.0;

   int step = (type == POSITION_TYPE_BUY ? S.gBuyCount : S.gSellCount);

   if(step < 0)
      step = 0;
   if(step >= S.gGridDepth)
      step = S.gGridDepth - 1;

   return NormalizeLot(S.gGridLots[step], S.symbol);
}


void CloseBasket(SymbolState &S, int type)
  {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket))
         continue;
      if(pos.Symbol() != S.symbol)
         continue;
      if(pos.Magic() != InpMagic)
         continue;
      if((int)pos.PositionType() != type)
         continue;
      trade.PositionClose(ticket);
     }
  }

void TrailBasket(SymbolState &S, int type, double baseStep)
  {
   double commissionPerLot = GetNormalizedCommission(S);
   double totalLots        = (type == POSITION_TYPE_BUY ? S.gBuyLots : S.gSellLots);
   double basketProfit     = (type == POSITION_TYPE_BUY ? S.gBuyProfit : S.gSellProfit);
   double swap             = (type == POSITION_TYPE_BUY ? S.gBuySwap : S.gSellSwap);

   if(totalLots <= 0.0)
      return;

   double marginPerLot;
   if(!GetMarginPerLot(S.symbol, type, S.gTick.bid, marginPerLot))
      return;

   double riskedMargin = marginPerLot * totalLots;
   // commissionPerLot is already the ROUND TURN, so it is not doubled again
   double commissionCost = commissionPerLot * totalLots;
   double profitNet      = basketProfit - commissionCost + swap;

   int sideDepth = InpGridSteps;
   int halfway   = (int)MathFloor(sideDepth / 2);
   int count     = (type == POSITION_TYPE_BUY ? S.gBuyCount : S.gSellCount);

   if(count >= halfway && profitNet >= 0.0)
     {
      CloseBasket(S, type);
      return;
     }

   if(profitNet >= riskedMargin)
     {
       CloseBasket(S, type);
     }
  }

void PlaceATRGrid(SymbolState &S)
  {
   if(!UpdateMarketData(S))
      return;

   double ATR   = GetAverageATR(S, 1);
   double baseStep = ATR;
   if(baseStep <= 0)
      return;

   double baseLot = CalcBaseLotFromGrid(S, baseStep);
   if(baseLot <= 0.0)
      return;

   // The ladder was measured against one step size. Space the levels with that
   // same step, not the live ATR, or the drawdown that was budgeted is not the
   // drawdown that occurs.
   baseStep = S.gGridBaseStep;

   TrailBasket(S, POSITION_TYPE_BUY, baseStep);
   TrailBasket(S, POSITION_TYPE_SELL, baseStep);

   bool allowTrading = SpreadOK(S) && !IsMarketClosingSoon(S.symbol);

   double commissionPerLot = GetNormalizedCommission(S);

   if(S.gBuyCount == 0 && ((S.gSellCount == 0) || (S.gTick.ask <= S.gHighestSell - baseStep)) && allowTrading)
     {
      double lot = baseLot;
      trade.SetExpertMagicNumber(InpMagic);
      if(CheckMoneyForTrade(S.symbol, lot, ORDER_TYPE_BUY, commissionPerLot))
        {
         if(trade.Buy(lot, S.symbol, S.gTick.ask, 0, 0))
           {
            S.gLowestBuy  = S.gTick.ask;
            S.gHighestBuy = S.gTick.ask;
           }
        }
     }

   if(S.gSellCount == 0 && ((S.gBuyCount == 0) || (S.gTick.bid >= S.gLowestBuy + baseStep)) && allowTrading)
     {
      double lot = baseLot;
      trade.SetExpertMagicNumber(InpMagic);
      if(CheckMoneyForTrade(S.symbol, lot, ORDER_TYPE_SELL, commissionPerLot))
        {
         if(trade.Sell(lot, S.symbol, S.gTick.bid, 0, 0))
           {
            S.gLowestSell  = S.gTick.bid;
            S.gHighestSell = S.gTick.bid;
           }
        }
     }

   if(S.gBuyCount > 0 && S.gBuyCount < S.gGridDepth)
     {
      double nextLevel = S.gLowestBuy - baseStep;
      bool allowBuy = (S.gSellCount == 0 || nextLevel < S.gHighestSell);
      if(allowBuy && S.gTick.ask <= nextLevel)
        {
         double lot = CalcProjectedLot(S, POSITION_TYPE_BUY, nextLevel, baseStep, baseLot);
         trade.SetExpertMagicNumber(InpMagic);
         if(CheckMoneyForTrade(S.symbol, lot, ORDER_TYPE_BUY, commissionPerLot))
           {
            if(trade.Buy(lot, S.symbol, S.gTick.ask, 0, 0))
              {
               S.gBuyCount++;
               if(S.gTick.bid < S.gLowestBuy)
                  S.gLowestBuy = S.gTick.bid;
               if(S.gTick.bid > S.gHighestBuy)
                  S.gHighestBuy = S.gTick.bid;
              }
           }
        }
     }

   if(S.gSellCount > 0 && S.gSellCount < S.gGridDepth)
     {
      double nextLevel = S.gHighestSell + baseStep;
      bool allowSell = (S.gBuyCount == 0 || nextLevel > S.gLowestBuy);
      if(allowSell && S.gTick.bid >= nextLevel)
        {
         double lot = CalcProjectedLot(S, POSITION_TYPE_SELL, nextLevel, baseStep, baseLot);
         trade.SetExpertMagicNumber(InpMagic);
         if(CheckMoneyForTrade(S.symbol, lot, ORDER_TYPE_SELL, commissionPerLot))
           {
            if(trade.Sell(lot, S.symbol, S.gTick.bid, 0, 0))
              {
               S.gSellCount++;
               if(S.gTick.ask > S.gHighestSell)
                  S.gHighestSell = S.gTick.ask;
               if(S.gTick.ask < S.gLowestSell)
                  S.gLowestSell  = S.gTick.ask;
              }
           }
        }
     }
  }

void MakeLabel(const string id, int x, int y, int size, color clr)
  {
   if(ObjectFind(0, id) == -1)
      ObjectCreate(0, id, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, id, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, id, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, id, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, id, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, id, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, id, OBJPROP_FONT, "Consolas");
  }

void CreateMintyPanel()
  {
   int x = 10, y = 40, h = 22;

   MakeLabel("Minty_header", x, y, 14, clrLimeGreen);
   MakeLabel("Minty_spread", x, y + h*2, 10, clrDarkGray);
   MakeLabel("Minty_orders", x, y + h*4, 10, clrDarkGray);
   MakeLabel("Minty_profit", x, y + h*6, 10, clrDarkGray);
   MakeLabel("Minty_target", x, y + h*8, 10, clrDarkGray);

   MakeLabel("Minty_spread_val", x+200, y + h*2, 10, clrLimeGreen);
   MakeLabel("Minty_buyOrders",  x+200, y + h*4, 10, clrDarkGray);
   MakeLabel("Minty_sellOrders", x+200, y + h*4 + h, 10, clrDarkGray);
   MakeLabel("Minty_buyProfit",  x+200, y + h*6, 10, clrDarkGray);
   MakeLabel("Minty_sellProfit", x+200, y + h*6 + h, 10, clrDarkGray);
   MakeLabel("Minty_buyTarget",  x+200, y + h*8, 10, clrDarkGray);
   MakeLabel("Minty_sellTarget", x+200, y + h*8 + h, 10, clrDarkGray);
  }

void UpdateMintyPanel(SymbolState &S, double baseStep)
  {
   ObjectSetString(0, "Minty_header", OBJPROP_TEXT, "MintyGrid 3.6 (DD basket)");

   ObjectSetString(0, "Minty_spread", OBJPROP_TEXT, "Spread:");
   ObjectSetString(0, "Minty_spread_val", OBJPROP_TEXT,
                   DoubleToString(S.gSpreadAvg,4) + "%");

   ObjectSetString(0, "Minty_orders", OBJPROP_TEXT, "Orders:");
   ObjectSetString(0, "Minty_buyOrders",  OBJPROP_TEXT, IntegerToString(S.gBuyCount));
   ObjectSetString(0, "Minty_sellOrders", OBJPROP_TEXT, IntegerToString(S.gSellCount));

   // net, on the same basis TrailBasket decides with: gross + swap - round turn
   double comm    = GetNormalizedCommission(S);
   double buyNet  = S.gBuyProfit  + S.gBuySwap  - comm * S.gBuyLots;
   double sellNet = S.gSellProfit + S.gSellSwap - comm * S.gSellLots;

   ObjectSetString(0, "Minty_profit", OBJPROP_TEXT, "Profit:");
   ObjectSetString(0, "Minty_buyProfit",  OBJPROP_TEXT, DoubleToString(buyNet,2));
   ObjectSetString(0, "Minty_sellProfit", OBJPROP_TEXT, DoubleToString(sellNet,2));

   // the figure the basket is actually closed on, not an unrelated one-step move
   int    halfway = (int)MathFloor(InpGridSteps / 2);
   double marginPerLot;

   double buyTarget = 0.0;
   if(S.gBuyCount > 0 && S.gBuyCount < halfway &&
      GetMarginPerLot(S.symbol, POSITION_TYPE_BUY, S.gTick.bid, marginPerLot))
      buyTarget = marginPerLot * S.gBuyLots;

   double sellTarget = 0.0;
   if(S.gSellCount > 0 && S.gSellCount < halfway &&
      GetMarginPerLot(S.symbol, POSITION_TYPE_SELL, S.gTick.bid, marginPerLot))
      sellTarget = marginPerLot * S.gSellLots;

   ObjectSetString(0, "Minty_target", OBJPROP_TEXT, "Target:");
   ObjectSetString(0, "Minty_buyTarget",  OBJPROP_TEXT, DoubleToString(buyTarget,2));
   ObjectSetString(0, "Minty_sellTarget", OBJPROP_TEXT, DoubleToString(sellTarget,2));
  }

void DrawGridSide(SymbolState &S, int type, double baseStep, double extremum, int count, color clr, string prefix)
  {
   if(type == POSITION_TYPE_BUY && S.gBuyCount == 0)
     {
      for(int i = 0; i < 64; i++)
        {
         ObjectDelete(0, prefix + "_L" + IntegerToString(i));
         ObjectDelete(0, prefix + "_T" + IntegerToString(i));
        }
      return;
     }

   if(type == POSITION_TYPE_SELL && S.gSellCount == 0)
     {
      for(int i = 0; i < 64; i++)
        {
         ObjectDelete(0, prefix + "_L" + IntegerToString(i));
         ObjectDelete(0, prefix + "_T" + IntegerToString(i));
        }
      return;
     }

   int depth = S.gGridDepth;
   datetime t = TimeCurrent();

   double anchor;
   if(type == POSITION_TYPE_BUY)
      anchor = (S.gBuyCount > 0 ? S.gLowestBuy : S.gTick.ask);
   else
      anchor = (S.gSellCount > 0 ? S.gHighestSell : S.gTick.bid);

   for(int i = 0; i < 64; i++)
     {
      string id  = prefix + "_L" + IntegerToString(i);
      string txt = prefix + "_T" + IntegerToString(i);

      if(i < count || i >= depth)
        {
         ObjectDelete(0,id);
         ObjectDelete(0,txt);
         continue;
        }

      int k = i - count + 1;

      double level = (type == POSITION_TYPE_BUY
                      ? anchor - baseStep * k
                      : anchor + baseStep * k);

      double lot = S.gGridLots[i];

      if(ObjectFind(0,id) == -1)
         ObjectCreate(0,id,OBJ_HLINE,0,0,level);

      ObjectSetDouble(0,id,OBJPROP_PRICE,level);
      ObjectSetInteger(0,id,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,id,OBJPROP_WIDTH,1);

      if(ObjectFind(0,txt) == -1)
         ObjectCreate(0,txt,OBJ_TEXT,0,t,level);

      ObjectSetDouble(0,txt,OBJPROP_PRICE,level);
      ObjectSetString(0,txt,OBJPROP_TEXT, DoubleToString(lot,2));
      ObjectSetInteger(0,txt,OBJPROP_COLOR,clrDarkGray);
      ObjectSetInteger(0,txt,OBJPROP_FONTSIZE,8);
     }
  }

void UpdateGridLinesAll(SymbolState &S, double baseStep)
  {
   DrawGridSide(S, POSITION_TYPE_BUY,  baseStep, S.gLowestBuy,  S.gBuyCount,  clrRoyalBlue, "MG_BUY");
   DrawGridSide(S, POSITION_TYPE_SELL, baseStep, S.gHighestSell, S.gSellCount, clrTomato,    "MG_SELL");
  }

void DrawSideProfitLine(SymbolState &S, int type, double baseStep, string id)
  {
   int count = (type == POSITION_TYPE_BUY ? S.gBuyCount : S.gSellCount);
   double lots = (type == POSITION_TYPE_BUY ? S.gBuyLots : S.gSellLots);

   if(lots <= 0.0)
     {
      ObjectDelete(0,id);
      return;
     }

   double commission = GetNormalizedCommission(S);
   double cost = commission * lots;

   double sumLotsOpen = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != S.symbol)
         continue;
      // lots above is magic-filtered, so this sum has to be too or the
      // break-even price is computed from two different sets of positions
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      sumLotsOpen += PositionGetDouble(POSITION_PRICE_OPEN) *
                     PositionGetDouble(POSITION_VOLUME);
     }

   double rhs = cost * S.gTickSize / S.gTickValue;

   double priceBE = (type == POSITION_TYPE_BUY ?
                     (sumLotsOpen + rhs) / lots :
                     (sumLotsOpen - rhs) / lots);

   bool isBreakevenPhase = (count >= (InpGridSteps / 2));
   color lineColor = (isBreakevenPhase ? clrOrange : clrLimeGreen);

   if(ObjectFind(0,id) == -1)
      ObjectCreate(0,id,OBJ_HLINE,0,0,priceBE);

   ObjectSetDouble(0,id,OBJPROP_PRICE,priceBE);
   ObjectSetInteger(0,id,OBJPROP_COLOR,lineColor);
   ObjectSetInteger(0,id,OBJPROP_WIDTH,2);
  }

void DrawProfitLines(SymbolState &S, double baseStep)
  {
   if(S.gBuyCount > 0)
      DrawSideProfitLine(S, POSITION_TYPE_BUY, baseStep, "MG_BUY_PROFIT");
   else
      ObjectDelete(0,"MG_BUY_PROFIT");

   if(S.gSellCount > 0)
      DrawSideProfitLine(S, POSITION_TYPE_SELL, baseStep, "MG_SELL_PROFIT");
   else
      ObjectDelete(0,"MG_SELL_PROFIT");
  }

int OnInit()
  {
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   if(n <= 0)
      return(INIT_FAILED);

   ArrayResize(gStates, n);

   for(int i=0; i<n; i++)
     {
      string sym = parts[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "")
         continue;

      if(!SymbolSelect(sym, true))
         return(INIT_FAILED);

      gStates[i].symbol = sym;

      gStates[i].atrHandleMN = iATR(sym, InpTimeframe, InpAtrPeriod);

      gStates[i].gBuyCount    = 0;
      gStates[i].gSellCount   = 0;
      gStates[i].gBuyLots     = 0.0;
      gStates[i].gSellLots    = 0.0;
      gStates[i].gBuyProfit   = 0.0;
      gStates[i].gSellProfit  = 0.0;
      gStates[i].gLowestBuy   = DBL_MAX;
      gStates[i].gHighestBuy  = -DBL_MAX;
      gStates[i].gLowestSell  = DBL_MAX;
      gStates[i].gHighestSell = -DBL_MAX;
      gStates[i].gBuyAvgPrice = 0.0;
      gStates[i].gSellAvgPrice= 0.0;

      gStates[i].gSpreadSum       = 0.0;
      gStates[i].gSpreadCount     = 0;
      gStates[i].gSpreadAvg       = 0.0;
      gStates[i].gSpreadStartTime = 0;

      gStates[i].gCommPerLot      = 0.0;
      gStates[i].gCommTime        = 0;
      gStates[i].gCommValid       = false;

      gStates[i].gTickSize  = 0.0;
      gStates[i].gTickValue = 0.0;
      gStates[i].gTickOk    = false;

      gStates[i].gGridDepth    = 0;
      gStates[i].gGridBaseStep = 0.0;
      ArrayInitialize(gStates[i].gGridLots, 0.0);
     }

   if(InpDrawChart)
      CreateMintyPanel();

   trade.SetExpertMagicNumber(InpMagic);
   ChartRedraw();
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   int n = ArraySize(gStates);
   if(n <= 0)
      return;

   for(int i=0; i<n; i++)
     {
      if(!IsMarketOpen(gStates[i].symbol))
         continue;

      ScanBaskets(gStates[i]);
      UpdateBasketAverages(gStates[i]);
      PlaceATRGrid(gStates[i]);
     }

   if(InpDrawChart && n > 0)
     {
      if(UpdateMarketData(gStates[0]))
        {
         // draw the step the ladder is frozen at, so the lines sit where the
         // levels will actually fill
         double baseStep = gStates[0].gGridBaseStep;
         if(baseStep <= 0.0)
            baseStep = GetAverageATR(gStates[0], 1);

         UpdateGridLinesAll(gStates[0], baseStep);
         UpdateMintyPanel(gStates[0], baseStep);
         DrawProfitLines(gStates[0], baseStep);
        }
     }
  }
