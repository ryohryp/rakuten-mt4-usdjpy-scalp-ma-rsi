#ifndef __AI_DATA_OUTCOME_TRACKER_MQH__
#define __AI_DATA_OUTCOME_TRACKER_MQH__

#include <AIData/CsvWriter.mqh>

#define AI_OUTCOME_TRACKER_VERSION "tick_bidask_m5_h48_v1"
#define AI_OUTCOME_TIMEFRAME PERIOD_M5
#define AI_OUTCOME_MAX_BARS 48

PendingOutcome gAiPendingOutcomes[];

int AiFindPendingOutcome(const string signalId)
{
   for(int i=0;i<ArraySize(gAiPendingOutcomes);i++)
      if(gAiPendingOutcomes[i].signalId==signalId) return i;
   return -1;
}

void AiRemovePendingOutcome(const int index)
{
   int size=ArraySize(gAiPendingOutcomes);
   if(index<0 || index>=size) return;
   int last=size-1;
   if(index!=last) gAiPendingOutcomes[index]=gAiPendingOutcomes[last];
   ArrayResize(gAiPendingOutcomes,last);
}

bool AiRegisterPendingOutcome(const string signalId,
                              const string signalKey,
                              const SignalFeatures &features)
{
   if(StringLen(signalId)==0 || features.riskPips<=0) return false;
   if(AiFindPendingOutcome(signalId)>=0) return true;

   int size=ArraySize(gAiPendingOutcomes);
   if(ArrayResize(gAiPendingOutcomes,size+1)!=size+1) return false;

   gAiPendingOutcomes[size].resolved=false;
   gAiPendingOutcomes[size].signalId=signalId;
   gAiPendingOutcomes[size].signalKey=signalKey;
   gAiPendingOutcomes[size].direction=features.direction;
   gAiPendingOutcomes[size].signalTime=features.signalTime;
   gAiPendingOutcomes[size].timeframe=AI_OUTCOME_TIMEFRAME;
   gAiPendingOutcomes[size].maxBars=AI_OUTCOME_MAX_BARS;
   gAiPendingOutcomes[size].entryPrice=features.virtualEntryPrice;
   gAiPendingOutcomes[size].slPrice=features.virtualSlPrice;
   gAiPendingOutcomes[size].tpPrice=features.virtualTpPrice;
   gAiPendingOutcomes[size].riskPips=features.riskPips;
   gAiPendingOutcomes[size].mfePips=0.0;
   gAiPendingOutcomes[size].maePips=0.0;
   gAiPendingOutcomes[size].outcome="";
   gAiPendingOutcomes[size].labelTpBeforeSl=-1;
   gAiPendingOutcomes[size].outcomeTime=0;
   gAiPendingOutcomes[size].barsToOutcome=0;
   gAiPendingOutcomes[size].secondsToOutcome=0;
   return true;
}

int AiOutcomeBarsElapsed(const PendingOutcome &pending)
{
   int shift=iBarShift(Symbol(),pending.timeframe,pending.signalTime,false);
   if(shift>=0) return shift;
   int secondsPerBar=pending.timeframe*60;
   if(secondsPerBar<=0 || TimeCurrent()<=pending.signalTime) return 0;
   return (int)((TimeCurrent()-pending.signalTime)/secondsPerBar);
}

void AiUpdateOutcomeExcursions(PendingOutcome &pending,const double pipSize)
{
   if(pipSize<=0) return;
   double favorable=0.0;
   double adverse=0.0;
   if(pending.direction==OP_BUY)
   {
      favorable=(Bid-pending.entryPrice)/pipSize;
      adverse=(pending.entryPrice-Bid)/pipSize;
   }
   else if(pending.direction==OP_SELL)
   {
      favorable=(pending.entryPrice-Ask)/pipSize;
      adverse=(Ask-pending.entryPrice)/pipSize;
   }
   if(favorable>pending.mfePips) pending.mfePips=favorable;
   if(adverse>pending.maePips) pending.maePips=adverse;
}

void AiResolvePendingOutcome(PendingOutcome &pending,
                             const string outcome,
                             const int label,
                             const int barsElapsed)
{
   int normalizedBars=barsElapsed<0 ? 0 : barsElapsed;
   long elapsedSeconds=(long)(TimeCurrent()-pending.signalTime);
   if(elapsedSeconds<0) elapsedSeconds=0;

   pending.resolved=true;
   pending.outcome=outcome;
   pending.labelTpBeforeSl=label;
   pending.outcomeTime=TimeCurrent();
   pending.barsToOutcome=normalizedBars;
   pending.secondsToOutcome=elapsedSeconds;
}

bool AiPersistPendingOutcome(const int index)
{
   if(index<0 || index>=ArraySize(gAiPendingOutcomes)) return false;
   if(!gAiPendingOutcomes[index].resolved) return false;
   if(!AiWriteOutcome(gAiRunId,gAiPendingOutcomes[index],AI_OUTCOME_TRACKER_VERSION))
   {
      AiWriteRuntimeError(gAiRunId,"OUTCOME","OUTCOME_LOG_FAILED",GetLastError(),
                          "signal_outcomes",gAiPendingOutcomes[index].signalId);
      return false;
   }
   AiRemovePendingOutcome(index);
   return true;
}

void AiUpdatePendingOutcomes(const double pipSize)
{
   if(ArraySize(gAiPendingOutcomes)==0) return;
   RefreshRates();
   if(Bid<=0 || Ask<=0) return;

   for(int i=ArraySize(gAiPendingOutcomes)-1;i>=0;i--)
   {
      if(gAiPendingOutcomes[i].resolved)
      {
         AiPersistPendingOutcome(i);
         continue;
      }

      AiUpdateOutcomeExcursions(gAiPendingOutcomes[i],pipSize);

      bool hitTp=false;
      bool hitSl=false;
      if(gAiPendingOutcomes[i].direction==OP_BUY)
      {
         hitTp=Bid>=gAiPendingOutcomes[i].tpPrice;
         hitSl=Bid<=gAiPendingOutcomes[i].slPrice;
      }
      else if(gAiPendingOutcomes[i].direction==OP_SELL)
      {
         hitTp=Ask<=gAiPendingOutcomes[i].tpPrice;
         hitSl=Ask>=gAiPendingOutcomes[i].slPrice;
      }

      int barsElapsed=AiOutcomeBarsElapsed(gAiPendingOutcomes[i]);
      if(hitTp && hitSl)
         AiResolvePendingOutcome(gAiPendingOutcomes[i],"AMBIGUOUS",-1,barsElapsed);
      else if(hitTp)
         AiResolvePendingOutcome(gAiPendingOutcomes[i],"TP_FIRST",1,barsElapsed);
      else if(hitSl)
         AiResolvePendingOutcome(gAiPendingOutcomes[i],"SL_FIRST",0,barsElapsed);
      else if(barsElapsed>=gAiPendingOutcomes[i].maxBars)
         AiResolvePendingOutcome(gAiPendingOutcomes[i],"EXPIRED",-1,barsElapsed);

      if(gAiPendingOutcomes[i].resolved) AiPersistPendingOutcome(i);
   }
}

void AiFinalizePendingOutcomes()
{
   for(int i=ArraySize(gAiPendingOutcomes)-1;i>=0;i--)
   {
      if(!gAiPendingOutcomes[i].resolved)
      {
         int barsElapsed=AiOutcomeBarsElapsed(gAiPendingOutcomes[i]);
         AiResolvePendingOutcome(gAiPendingOutcomes[i],"TRUNCATED",-1,barsElapsed);
      }
      AiPersistPendingOutcome(i);
   }
}

int AiPendingOutcomeCount()
{
   return ArraySize(gAiPendingOutcomes);
}

#endif
