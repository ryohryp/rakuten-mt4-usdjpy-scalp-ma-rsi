#ifndef __AI_DATA_SIGNAL_LOGGER_MQH__
#define __AI_DATA_SIGNAL_LOGGER_MQH__

#include <AIData/RunContext.mqh>
#include <AIData/CsvWriter.mqh>

bool LogSignalCandidate(const string signalId,
                        const string signalKey,
                        const SignalFeatures &features,
                        const string strategyVersion,
                        const string featureSchemaVersion,
                        const string labelVersion)
{
   return AiWriteCandidate(gAiRunId,signalId,signalKey,features,strategyVersion,
                           featureSchemaVersion,labelVersion);
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
