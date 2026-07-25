#ifndef __AI_DATA_TRADE_RESULT_LOGGER_MQH__
#define __AI_DATA_TRADE_RESULT_LOGGER_MQH__

#include <AIData/RunContext.mqh>
#include <AIData/CsvWriter.mqh>

TrackedTrade gAiTrackedTrades[];

int AiFindTrackedTrade(const int ticket)
{
   for(int i=0;i<ArraySize(gAiTrackedTrades);i++)
      if(gAiTrackedTrades[i].ticket==ticket) return i;
   return -1;
}

bool AiRegisterTrade(const string signalId,
                     const string signalKey,
                     const int ticket,
                     const double initialRiskMoney)
{
   if(ticket<=0) return false;
   if(AiFindTrackedTrade(ticket)>=0) return true;
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return false;

   int size=ArraySize(gAiTrackedTrades);
   if(ArrayResize(gAiTrackedTrades,size+1)!=size+1) return false;
   gAiTrackedTrades[size].active=true;
   gAiTrackedTrades[size].logged=false;
   gAiTrackedTrades[size].signalId=signalId;
   gAiTrackedTrades[size].signalKey=signalKey;
   gAiTrackedTrades[size].ticket=ticket;
   gAiTrackedTrades[size].direction=OrderType();
   gAiTrackedTrades[size].entryTime=OrderOpenTime();
   gAiTrackedTrades[size].lots=OrderLots();
   gAiTrackedTrades[size].entryPrice=OrderOpenPrice();
   gAiTrackedTrades[size].initialSl=OrderStopLoss();
   gAiTrackedTrades[size].initialTp=OrderTakeProfit();
   gAiTrackedTrades[size].initialRiskMoney=initialRiskMoney;
   gAiTrackedTrades[size].mfePips=0.0;
   gAiTrackedTrades[size].maePips=0.0;
   return true;
}

string AiDetectExitReason(const TrackedTrade &trade,
                          const double exitPrice,
                          const double finalSl,
                          const double pipSize)
{
   double tolerance=MathMax(Point*3,pipSize*0.10);
   if(trade.direction==OP_BUY)
   {
      if(trade.initialTp>0 && exitPrice>=trade.initialTp-tolerance) return "TP";
      if(finalSl>0 && exitPrice<=finalSl+tolerance)
      {
         if(finalSl>=trade.entryPrice-pipSize*0.30) return "BE";
         if(finalSl>trade.initialSl+tolerance) return "TRAIL";
         return "SL";
      }
   }
   else if(trade.direction==OP_SELL)
   {
      if(trade.initialTp>0 && exitPrice<=trade.initialTp+tolerance) return "TP";
      if(finalSl>0 && exitPrice>=finalSl-tolerance)
      {
         if(finalSl<=trade.entryPrice+pipSize*0.30) return "BE";
         if(finalSl<trade.initialSl-tolerance) return "TRAIL";
         return "SL";
      }
   }
   return "OTHER";
}

void AiUpdateOpenExcursions(TrackedTrade &trade,const double pipSize)
{
   if(pipSize<=0) return;
   double favorable=0.0;
   double adverse=0.0;
   if(trade.direction==OP_BUY)
   {
      favorable=(Bid-trade.entryPrice)/pipSize;
      adverse=(trade.entryPrice-Bid)/pipSize;
   }
   else if(trade.direction==OP_SELL)
   {
      favorable=(trade.entryPrice-Ask)/pipSize;
      adverse=(Ask-trade.entryPrice)/pipSize;
   }
   if(favorable>trade.mfePips) trade.mfePips=favorable;
   if(adverse>trade.maePips) trade.maePips=adverse;
}

void AiUpdateTrackedTrades(const double pipSize)
{
   for(int i=0;i<ArraySize(gAiTrackedTrades);i++)
   {
      if(!gAiTrackedTrades[i].active || gAiTrackedTrades[i].logged) continue;
      int ticket=gAiTrackedTrades[i].ticket;
      if(!OrderSelect(ticket,SELECT_BY_TICKET)) continue;

      if(OrderCloseTime()==0)
      {
         AiUpdateOpenExcursions(gAiTrackedTrades[i],pipSize);
         continue;
      }

      string exitReason=AiDetectExitReason(gAiTrackedTrades[i],OrderClosePrice(),
                                           OrderStopLoss(),pipSize);
      if(AiWriteTradeResult(gAiRunId,gAiTrackedTrades[i],OrderCloseTime(),OrderClosePrice(),
                            OrderProfit(),OrderCommission(),OrderSwap(),exitReason))
      {
         gAiTrackedTrades[i].logged=true;
         gAiTrackedTrades[i].active=false;
      }
      else
      {
         AiWriteRuntimeError(gAiRunId,"TRADE_RESULT","TRADE_LOG_FAILED",GetLastError(),
                             "trade_results",gAiTrackedTrades[i].signalId);
      }
   }
}

#endif
