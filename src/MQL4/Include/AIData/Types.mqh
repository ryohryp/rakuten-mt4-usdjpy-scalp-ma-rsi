#ifndef __AI_DATA_TYPES_MQH__
#define __AI_DATA_TYPES_MQH__

struct SignalFeatures
{
   datetime signalTime;
   long signalEpoch;
   int direction;
   string setupType;
   string sessionTag;
   double bid;
   double ask;
   double spreadPips;
   double virtualEntryPrice;
   double virtualSlPrice;
   double virtualTpPrice;
   double riskPips;
   double rewardPips;
   double atrPips;
   double atrChange;
   double rsi;
   double adx;
   int h1Trend;
   double rangeWidthPips;
   double breakoutStrength;
   double bodyPips;
   double upperWickPips;
   double lowerWickPips;
   long tickVolume;
};

struct DecisionResult
{
   bool eligible;
   string failedStage;
   string reasonCode;
   string finalDecision;
   int ticket;
   int orderError;
};

struct TrackedTrade
{
   bool active;
   bool logged;
   string signalId;
   string signalKey;
   int ticket;
   int direction;
   datetime entryTime;
   double lots;
   double entryPrice;
   double initialSl;
   double initialTp;
   double initialRiskMoney;
   double mfePips;
   double maePips;
};

void ResetDecisionResult(DecisionResult &result)
{
   result.eligible=true;
   result.failedStage="FINAL";
   result.reasonCode="TRADE_ALLOWED";
   result.finalDecision="SKIP";
   result.ticket=-1;
   result.orderError=0;
}

string AiDirectionName(const int direction)
{
   if(direction==OP_BUY) return "BUY";
   if(direction==OP_SELL) return "SELL";
   return "UNKNOWN";
}

string AiDirectionCode(const int direction)
{
   if(direction==OP_BUY) return "B";
   if(direction==OP_SELL) return "S";
   return "X";
}

#endif
