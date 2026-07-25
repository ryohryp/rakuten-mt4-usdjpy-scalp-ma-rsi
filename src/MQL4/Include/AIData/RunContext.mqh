#ifndef __AI_DATA_RUN_CONTEXT_MQH__
#define __AI_DATA_RUN_CONTEXT_MQH__

#include <AIData/Types.mqh>

string gAiRunId="";
string gAiParameterHash="";
datetime gAiRunStartTime=0;
int gAiSignalSequence=0;

string AiHexDigit(const int value)
{
   return StringSubstr("0123456789abcdef",value,1);
}

string AiHex8(const uint value)
{
   string output="";
   for(int i=7;i>=0;i--)
   {
      int nibble=(int)((value>>(i*4))&0x0F);
      output+=AiHexDigit(nibble);
   }
   return output;
}

uint AiFnv1a32(const string value)
{
   uint hash=0x811C9DC5;
   int length=StringLen(value);
   for(int i=0;i<length;i++)
   {
      hash^=(uint)StringGetCharacter(value,i);
      hash*=0x01000193;
   }
   return hash;
}

string AiSanitizeToken(string value)
{
   StringReplace(value,".","");
   StringReplace(value,":","");
   StringReplace(value," ","_");
   StringReplace(value,"/","-");
   StringReplace(value,"\\","-");
   StringReplace(value,"|","-");
   return value;
}

string AiPad3(const int value)
{
   int normalized=value%1000;
   if(normalized<0) normalized=-normalized;
   if(normalized<10) return "00"+IntegerToString(normalized);
   if(normalized<100) return "0"+IntegerToString(normalized);
   return IntegerToString(normalized);
}

string AiDataSource()
{
   if(IsTesting()) return "BACKTEST";
   if(IsDemo()) return "FORWARD";
   return "LIVE";
}

void AiInitializeRunContext(const int timeframe,
                            const int spreadPoints,
                            const string parameterFingerprint)
{
   datetime marketNow=TimeCurrent();
   if(marketNow<=0) marketNow=TimeLocal();
   datetime localNow=TimeLocal();
   gAiRunStartTime=marketNow;
   gAiParameterHash=AiHex8(AiFnv1a32(parameterFingerprint));
   string marketStamp=AiSanitizeToken(TimeToString(marketNow,TIME_DATE|TIME_MINUTES));
   string localStamp=AiSanitizeToken(TimeToString(localNow,TIME_DATE|TIME_SECONDS));
   string source=IsTesting() ? "BT" : (IsDemo() ? "FW" : "LIVE");
   gAiRunId=source+"_"+marketStamp+"_"+localStamp+
            "_M"+IntegerToString(timeframe)+
            "_"+IntegerToString(spreadPoints)+"PT_"+gAiParameterHash+"_"+
            IntegerToString((int)(GetTickCount()%100000));
   gAiSignalSequence=0;
}

string AiCreateSignalId(const int direction,const datetime signalTime)
{
   gAiSignalSequence++;
   return gAiRunId+"|"+Symbol()+"|"+AiDirectionCode(direction)+"|"+
          IntegerToString((int)signalTime)+"|"+AiPad3(gAiSignalSequence);
}

string AiCreateSignalKey(const int direction,const datetime signalTime)
{
   return AiDirectionCode(direction)+IntegerToString((int)signalTime)+AiPad3(gAiSignalSequence);
}

#endif
