#ifndef __AI_DATA_SIGNAL_LOGGER_MQH__
#define __AI_DATA_SIGNAL_LOGGER_MQH__

#include <AIData/RunContext.mqh>
#include <AIData/CsvWriter.mqh>
#include <AIData/OutcomeTracker.mqh>

bool LogSignalCandidate(const string signalId,
                        const string signalKey,
                        const SignalFeatures &features,
                        const string strategyVersion,
                        const string featureSchemaVersion,
                        const string labelVersion)
{
   bool written=AiWriteCandidate(gAiRunId,signalId,signalKey,features,strategyVersion,
                                 featureSchemaVersion,labelVersion);
   if(!written) return false;

   if(!AiRegisterPendingOutcome(signalId,signalKey,features))
      AiWriteRuntimeError(gAiRunId,"OUTCOME_REGISTER","OUTCOME_REGISTER_FAILED",
                          GetLastError(),"signal_outcomes",signalId);
   return true;
}

bool LogSignalDecision(const string signalId,
                       const string signalKey,
                       const DecisionResult &decision)
{
   return AiWriteDecision(gAiRunId,signalId,signalKey,decision);
}

void LogRuntimeError(const string eventType,
                     const string reasonCode,
                     const int errorCode,
                     const string fileName,
                     const string signalId)
{
   AiWriteRuntimeError(gAiRunId,eventType,reasonCode,errorCode,fileName,signalId);
}

#endif
