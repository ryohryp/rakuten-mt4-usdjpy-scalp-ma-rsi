#ifndef __AI_DATA_CSV_WRITER_MQH__
#define __AI_DATA_CSV_WRITER_MQH__

#include <AIData/RunContext.mqh>

int gAiManifestHandle=INVALID_HANDLE;
int gAiCandidateHandle=INVALID_HANDLE;
int gAiDecisionHandle=INVALID_HANDLE;
int gAiTradeHandle=INVALID_HANDLE;
int gAiErrorHandle=INVALID_HANDLE;
int gAiCandidateRows=0;
int gAiDecisionRows=0;
int gAiTradeRows=0;
int gAiErrorRows=0;
int gAiFlushEveryN=1;

string AiFormatDouble(const double value,const int digits)
{
   if(value==EMPTY_VALUE || !MathIsValidNumber(value)) return "";
   return DoubleToString(value,digits);
}

string AiFormatTime(const datetime value)
{
   if(value<=0) return "";
   return TimeToString(value,TIME_DATE|TIME_SECONDS);
}

void AiCloseHandle(int &handle)
{
   if(handle==INVALID_HANDLE) return;
   FileFlush(handle);
   FileClose(handle);
   handle=INVALID_HANDLE;
}

void AiFlushByCount(const int handle,int &rowCount)
{
   rowCount++;
   if(gAiFlushEveryN<=1 || rowCount%gAiFlushEveryN==0)
      FileFlush(handle);
}

int AiOpenCsv(const string path)
{
   ResetLastError();
   return FileOpen(path,FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ|FILE_ANSI,',');
}

void AiLoggerShutdown()
{
   AiCloseHandle(gAiManifestHandle);
   AiCloseHandle(gAiCandidateHandle);
   AiCloseHandle(gAiDecisionHandle);
   AiCloseHandle(gAiTradeHandle);
   AiCloseHandle(gAiErrorHandle);
}

bool AiLoggerInitialize(const string runId,const int flushEveryN)
{
   FolderCreate("AIData");
   gAiFlushEveryN=(int)MathMax(1,flushEveryN);
   string prefix="AIData\\";
   gAiManifestHandle=AiOpenCsv(prefix+"run_manifest_"+runId+".csv");
   gAiCandidateHandle=AiOpenCsv(prefix+"signal_candidates_"+runId+".csv");
   gAiDecisionHandle=AiOpenCsv(prefix+"signal_decisions_"+runId+".csv");
   gAiTradeHandle=AiOpenCsv(prefix+"trade_results_"+runId+".csv");
   gAiErrorHandle=AiOpenCsv(prefix+"runtime_errors_"+runId+".csv");

   if(gAiManifestHandle==INVALID_HANDLE || gAiCandidateHandle==INVALID_HANDLE ||
      gAiDecisionHandle==INVALID_HANDLE || gAiTradeHandle==INVALID_HANDLE ||
      gAiErrorHandle==INVALID_HANDLE)
   {
      Print("AIData logger initialization failed. Err=",GetLastError());
      AiLoggerShutdown();
      return false;
   }

   if(FileSize(gAiManifestHandle)==0)
      FileWrite(gAiManifestHandle,"run_id","data_source","start_time","symbol",
                "signal_timeframe","ea_version","strategy_version",
                "feature_schema_version","label_version","parameter_hash",
                "spread_mode","initial_deposit","terminal_build","broker_server");
   if(FileSize(gAiCandidateHandle)==0)
      FileWrite(gAiCandidateHandle,"run_id","signal_id","signal_key","signal_time",
                "signal_epoch","symbol","direction","setup_type","strategy_version",
                "feature_schema_version","label_version","server_hour","weekday",
                "session_tag","bid","ask","spread_pips","virtual_entry_price",
                "virtual_sl_price","virtual_tp_price","risk_pips","reward_pips",
                "atr_pips","atr_change","rsi","adx","h1_trend","range_width_pips",
                "breakout_strength","body_pips","upper_wick_pips","lower_wick_pips",
                "tick_volume");
   if(FileSize(gAiDecisionHandle)==0)
      FileWrite(gAiDecisionHandle,"run_id","signal_id","signal_key","decision_time",
                "deterministic_eligible","failed_stage","reason_code","ai_mode",
                "ai_probability","ai_threshold","model_version","final_decision",
                "ticket","order_error");
   if(FileSize(gAiTradeHandle)==0)
      FileWrite(gAiTradeHandle,"run_id","signal_id","signal_key","ticket","direction",
                "entry_time","exit_time","lots","entry_price","exit_price",
                "initial_sl","initial_tp","profit","commission","swap","net_profit",
                "initial_risk_money","realized_r","exit_reason","holding_seconds",
                "mfe_pips","mae_pips");
   if(FileSize(gAiErrorHandle)==0)
      FileWrite(gAiErrorHandle,"run_id","error_time","event_type","reason_code",
                "error_code","file_name","signal_id");

   FileSeek(gAiManifestHandle,0,SEEK_END);
   FileSeek(gAiCandidateHandle,0,SEEK_END);
   FileSeek(gAiDecisionHandle,0,SEEK_END);
   FileSeek(gAiTradeHandle,0,SEEK_END);
   FileSeek(gAiErrorHandle,0,SEEK_END);
   return true;
}

bool AiWriteRunManifest(const string runId,
                        const string dataSource,
                        const datetime startTime,
                        const int signalTimeframe,
                        const string eaVersion,
                        const string strategyVersion,
                        const string featureSchemaVersion,
                        const string labelVersion,
                        const string parameterHash,
                        const string spreadMode)
{
   if(gAiManifestHandle==INVALID_HANDLE) return false;
   datetime manifestStart=gAiRunStartTime>0 ? gAiRunStartTime : startTime;
   ResetLastError();
   uint written=FileWrite(gAiManifestHandle,runId,dataSource,AiFormatTime(manifestStart),Symbol(),
                          signalTimeframe,eaVersion,strategyVersion,featureSchemaVersion,
                          labelVersion,parameterHash,spreadMode,AiFormatDouble(AccountBalance(),2),
                          (int)TerminalInfoInteger(TERMINAL_BUILD),AccountServer());
   if(written==0) return false;
   FileFlush(gAiManifestHandle);
   return true;
}

bool AiWriteCandidate(const string runId,
                      const string signalId,
                      const string signalKey,
                      const SignalFeatures &features,
                      const string strategyVersion,
                      const string featureSchemaVersion,
                      const string labelVersion)
{
   if(gAiCandidateHandle==INVALID_HANDLE) return false;
   ResetLastError();
   uint written=FileWrite(gAiCandidateHandle,runId,signalId,signalKey,
                          AiFormatTime(features.signalTime),IntegerToString((int)features.signalEpoch),
                          Symbol(),AiDirectionName(features.direction),features.setupType,
                          strategyVersion,featureSchemaVersion,labelVersion,
                          TimeHour(features.signalTime),TimeDayOfWeek(features.signalTime),
                          features.sessionTag,AiFormatDouble(features.bid,Digits),
                          AiFormatDouble(features.ask,Digits),AiFormatDouble(features.spreadPips,2),
                          AiFormatDouble(features.virtualEntryPrice,Digits),
                          AiFormatDouble(features.virtualSlPrice,Digits),
                          AiFormatDouble(features.virtualTpPrice,Digits),
                          AiFormatDouble(features.riskPips,2),AiFormatDouble(features.rewardPips,2),
                          AiFormatDouble(features.atrPips,2),AiFormatDouble(features.atrChange,4),
                          AiFormatDouble(features.rsi,2),AiFormatDouble(features.adx,2),
                          features.h1Trend,AiFormatDouble(features.rangeWidthPips,2),
                          AiFormatDouble(features.breakoutStrength,4),
                          AiFormatDouble(features.bodyPips,2),
                          AiFormatDouble(features.upperWickPips,2),
                          AiFormatDouble(features.lowerWickPips,2),
                          IntegerToString((int)features.tickVolume));
   if(written==0) return false;
   AiFlushByCount(gAiCandidateHandle,gAiCandidateRows);
   return true;
}

bool AiWriteDecision(const string runId,
                     const string signalId,
                     const string signalKey,
                     const DecisionResult &decision)
{
   if(gAiDecisionHandle==INVALID_HANDLE) return false;
   string ticket=decision.ticket>0 ? IntegerToString(decision.ticket) : "";
   string orderError=decision.orderError>0 ? IntegerToString(decision.orderError) : "";
   ResetLastError();
   uint written=FileWrite(gAiDecisionHandle,runId,signalId,signalKey,
                          AiFormatTime(TimeCurrent()),decision.eligible ? 1 : 0,
                          decision.failedStage,decision.reasonCode,"OFF","","","",
                          decision.finalDecision,ticket,orderError);
   if(written==0) return false;
   AiFlushByCount(gAiDecisionHandle,gAiDecisionRows);
   return true;
}

bool AiWriteTradeResult(const string runId,
                        const TrackedTrade &trade,
                        const datetime exitTime,
                        const double exitPrice,
                        const double profit,
                        const double commission,
                        const double swap,
                        const string exitReason)
{
   if(gAiTradeHandle==INVALID_HANDLE) return false;
   double netProfit=profit+commission+swap;
   double realizedR=trade.initialRiskMoney>0 ? netProfit/trade.initialRiskMoney : EMPTY_VALUE;
   ResetLastError();
   uint written=FileWrite(gAiTradeHandle,runId,trade.signalId,trade.signalKey,trade.ticket,
                          AiDirectionName(trade.direction),AiFormatTime(trade.entryTime),
                          AiFormatTime(exitTime),AiFormatDouble(trade.lots,2),
                          AiFormatDouble(trade.entryPrice,Digits),AiFormatDouble(exitPrice,Digits),
                          AiFormatDouble(trade.initialSl,Digits),AiFormatDouble(trade.initialTp,Digits),
                          AiFormatDouble(profit,2),AiFormatDouble(commission,2),AiFormatDouble(swap,2),
                          AiFormatDouble(netProfit,2),AiFormatDouble(trade.initialRiskMoney,2),
                          AiFormatDouble(realizedR,4),exitReason,
                          IntegerToString((int)(exitTime-trade.entryTime)),
                          AiFormatDouble(trade.mfePips,2),AiFormatDouble(trade.maePips,2));
   if(written==0) return false;
   AiFlushByCount(gAiTradeHandle,gAiTradeRows);
   return true;
}

bool AiWriteRuntimeError(const string runId,
                         const string eventType,
                         const string reasonCode,
                         const int errorCode,
                         const string fileName,
                         const string signalId)
{
   if(gAiErrorHandle==INVALID_HANDLE)
   {
      Print("AIData error: ",eventType," ",reasonCode," code=",errorCode);
      return false;
   }
   ResetLastError();
   uint written=FileWrite(gAiErrorHandle,runId,AiFormatTime(TimeCurrent()),eventType,
                          reasonCode,errorCode,fileName,signalId);
   if(written==0) return false;
   AiFlushByCount(gAiErrorHandle,gAiErrorRows);
   return true;
}

#endif
