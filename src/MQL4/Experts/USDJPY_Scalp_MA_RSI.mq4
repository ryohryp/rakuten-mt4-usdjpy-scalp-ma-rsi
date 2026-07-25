//+------------------------------------------------------------------+
//| USDJPY_Scalp_MA_RSI.mq4                                         |
//| Pullback/reclaim strategy for Rakuten MT4 USDJPY                 |
//+------------------------------------------------------------------+
#property strict

#include <AIData/Types.mqh>
#include <AIData/RunContext.mqh>
#include <AIData/CsvWriter.mqh>
#include <AIData/SignalLogger.mqh>
#include <AIData/TradeResultLogger.mqh>

#define EA_VERSION "phase1_logging_v1"

input int InpTimeframe=PERIOD_M5;
input int FastEMA=5;
input int SlowEMA=20;
input int RSIPeriod=14;
input double RSIReclaimLevel=50.0;
input double RSIMomentumBuffer=2.0;
input int PullbackLookbackBars=3;
input double PullbackTolerancePips=0.5;
input bool RequireReclaimCandle=true;
input bool RequireADXRising=false;

input bool EnableDatasetLogging=true;
input string FeatureSchemaVersion="1.0.0";
input string LabelVersion="tp15_sl10_h48_v1";
input string StrategyVersion="pullback_reclaim_v2";
input int LogFlushEveryN=1;

enum RiskMode { FixedLot=0, RiskPercent=1 };
input RiskMode LotMode=RiskPercent;
input double FixedLots=0.10;
input double RiskPercentPerTrade=0.25;

enum SLTPMode { UseFixed=0, UseATR=1 };
input SLTPMode SLTP_CalcMode=UseATR;
input double SL_FixedPips=6.0;
input double TP_FixedPips=9.0;
input int ATRPeriod=14;
input double SL_ATR_Mult=1.0;
input double TP_ATR_Mult=1.5;

input bool UseTrailing=false;
input double TrailStartR=1.2;
input double TrailDistanceR=0.8;
input double TrailStepPips=0.5;
input bool UseBreakEven=false;
input double BE_Trigger_R=1.0;
input double BE_Offset_Pips=0.2;

input double MaxSpreadPips=0.8;
input double MaxSpreadATRRatio=0.20;
input int SlippagePoints=3;
input int CooldownMinutes=5;
input int MaxTradesPerDay=8;
input int MaxConsecLoss=3;
input double MaxDailyLossPercent=0.50;

// Broker-server time. Adjust when the broker's DST offset changes.
input bool UseTokyo=false;
input bool UseEurope=false;
input bool UseNY=true;
input int TokyoStartHour=2;
input int TokyoEndHour=10;
input int EuropeStartHour=9;
input int EuropeEndHour=18;
input int NYStartHour=14;
input int NYEndHour=0;
input bool UseManualSessionFilter=false;
input string ManualSessionRanges="";

input bool DebugMode=true;
input double MinATR_Pips=3.0;
input int MagicNumber=20251101;
input int ADXPeriod=14;
input double ADXThreshold=20.0;
input bool UseMTF_Filter=true;
input int MTF_Timeframe=PERIOD_H1;
input int MTF_MA_Period=20;
input bool RequireMTFPriceAlignment=true;

datetime lastEntryTime=0;
datetime lastSignalBar=0;
string gvLastEntryKey="";
bool datasetLoggerReady=false;

//--- price helpers
double PipSize(){ return 0.01; }
double PipToPoints(double pips){ return Point>0 ? pips*PipSize()/Point : 0.0; }
double PointsToPips(double points){
   double ppp=PipSize()/Point;
   return ppp>0 ? points/ppp : 0.0;
}
double PriceToPips(double distance){ return MathAbs(distance)/PipSize(); }
double SpreadPips(){ return PointsToPips(MarketInfo(Symbol(),MODE_SPREAD)); }
double SignedProfitPips(int type,double openPrice){
   if(type==OP_BUY) return (Bid-openPrice)/PipSize();
   if(type==OP_SELL) return (openPrice-Ask)/PipSize();
   return 0.0;
}
string BoolToken(bool value){ return value ? "1" : "0"; }

//--- session helpers
string Trim(string value){ return StringTrimRight(StringTrimLeft(value)); }
bool ParseMinutes(string value,int &minutes){
   value=Trim(value);
   int pos=StringFind(value,":");
   if(pos<=0) return false;
   int hour=(int)StrToInteger(StringSubstr(value,0,pos));
   int minute=(int)StrToInteger(StringSubstr(value,pos+1));
   if(hour<0 || hour>23 || minute<0 || minute>59) return false;
   minutes=hour*60+minute;
   return true;
}
bool InRange(int current,int startValue,int endValue){
   if(startValue==endValue) return false;
   if(endValue<startValue) return current>=startValue || current<endValue;
   return current>=startValue && current<endValue;
}
bool InManualSession(){
   string ranges=Trim(ManualSessionRanges);
   if(StringLen(ranges)==0) return false;
   string entries[];
   int count=StringSplit(ranges,(ushort)';',entries);
   int now=TimeHour(TimeCurrent())*60+TimeMinute(TimeCurrent());
   bool valid=false;
   for(int i=0;i<count;i++){
      string token=Trim(entries[i]);
      int dash=StringFind(token,"-");
      if(dash<=0) continue;
      int startMinute=0,endMinute=0;
      if(!ParseMinutes(StringSubstr(token,0,dash),startMinute) ||
         !ParseMinutes(StringSubstr(token,dash+1),endMinute)) continue;
      valid=true;
      if(InRange(now,startMinute,endMinute)) return true;
   }
   if(!valid && DebugMode) Print("DBG: invalid ManualSessionRanges=",ManualSessionRanges);
   return false;
}
bool TradingSession(){
   if(UseManualSessionFilter) return InManualSession();
   if(!UseTokyo && !UseEurope && !UseNY) return false;
   int now=TimeHour(TimeCurrent())*60;
   return (UseTokyo && InRange(now,TokyoStartHour*60,TokyoEndHour*60)) ||
          (UseEurope && InRange(now,EuropeStartHour*60,EuropeEndHour*60)) ||
          (UseNY && InRange(now,NYStartHour*60,NYEndHour*60));
}
string SessionTag(datetime value){
   int current=TimeHour(value)*60+TimeMinute(value);
   bool tokyo=InRange(current,TokyoStartHour*60,TokyoEndHour*60);
   bool europe=InRange(current,EuropeStartHour*60,EuropeEndHour*60);
   bool ny=InRange(current,NYStartHour*60,NYEndHour*60);
   int active=(tokyo?1:0)+(europe?1:0)+(ny?1:0);
   if(active>1) return "OVERLAP";
   if(tokyo) return "TOKYO";
   if(europe) return "EUROPE";
   if(ny) return "NY";
   return "OTHER";
}

//--- daily limits
datetime TodayStart(){ return StrToTime(TimeToString(TimeCurrent(),TIME_DATE)); }
bool CooldownPassed(){
   datetime value=lastEntryTime;
   if(value==0 && GlobalVariableCheck(gvLastEntryKey)){
      value=(datetime)GlobalVariableGet(gvLastEntryKey);
      lastEntryTime=value;
   }
   if(value==0 || value>TimeCurrent()) return true;
   return TimeCurrent()-value>=CooldownMinutes*60;
}
int TradesToday(){
   int count=0;
   datetime start=TodayStart();
   for(int i=OrdersHistoryTotal()-1;i>=0;i--){
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start) count++;
   }
   for(int j=0;j<OrdersTotal();j++){
      if(!OrderSelect(j,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start) count++;
   }
   return count;
}
double ClosedNetToday(){
   double total=0.0;
   datetime start=TodayStart();
   for(int i=OrdersHistoryTotal()-1;i>=0;i--){
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderCloseTime()<start) continue;
      total+=OrderProfit()+OrderSwap()+OrderCommission();
   }
   return total;
}
bool DailyLossReached(){
   if(MaxDailyLossPercent<=0) return false;
   double pnl=ClosedNetToday();
   double startBalance=AccountBalance()-pnl;
   if(startBalance<=0) startBalance=AccountBalance();
   double limit=startBalance*MaxDailyLossPercent/100.0;
   if(limit>0 && pnl<=-limit){
      Print("Daily loss cap reached. P/L=",DoubleToString(pnl,2),
            " limit=",DoubleToString(-limit,2));
      return true;
   }
   return false;
}
int ConsecutiveLossesToday(){
   int losses=0;
   datetime dayStart=TodayStart();
   datetime beforeTime=TimeCurrent()+1;
   int beforeTicket=2147483647;
   while(true){
      bool found=false;
      datetime latestTime=0;
      int latestTicket=-1;
      double latestProfit=0.0;
      for(int i=OrdersHistoryTotal()-1;i>=0;i--){
         if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
         if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
         if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
         datetime closeTime=OrderCloseTime();
         int ticket=OrderTicket();
         if(closeTime<dayStart || closeTime>beforeTime) continue;
         if(closeTime==beforeTime && ticket>=beforeTicket) continue;
         if(!found || closeTime>latestTime ||
            (closeTime==latestTime && ticket>latestTicket)){
            found=true;
            latestTime=closeTime;
            latestTicket=ticket;
            latestProfit=OrderProfit()+OrderSwap()+OrderCommission();
         }
      }
      if(!found) break;
      if(latestProfit<0) losses++;
      else if(latestProfit>0) break;
      beforeTime=latestTime;
      beforeTicket=latestTicket;
   }
   return losses;
}
bool HasPosition(){
   for(int i=0;i<OrdersTotal();i++){
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber &&
         (OrderType()==OP_BUY || OrderType()==OP_SELL)) return true;
   }
   return false;
}

//--- lot sizing
double PipValuePerLot(){
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSizePrice=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickValue<=0 || tickSizePrice<=0) return 0.0;
   return tickValue*PipSize()/tickSizePrice;
}
int LotDigits(double step){
   int digits=0;
   while(digits<8 && MathAbs(step-NormalizeDouble(step,digits))>0.00000001) digits++;
   return digits;
}
double NormalizeLotsDown(double lots){
   double minLot=MarketInfo(Symbol(),MODE_MINLOT);
   double maxLot=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(minLot<=0 || maxLot<=0 || step<=0) return 0.0;
   lots=MathMin(lots,maxLot);
   lots=MathFloor((lots+0.00000001)/step)*step;
   if(lots<minLot) return 0.0;
   return NormalizeDouble(lots,LotDigits(step));
}
double LotsByRisk(double stopPips){
   if(stopPips<=0 || RiskPercentPerTrade<=0) return 0.0;
   double pipValue=PipValuePerLot();
   if(pipValue<=0) return 0.0;
   return NormalizeLotsDown(
      AccountBalance()*(RiskPercentPerTrade/100.0)/(stopPips*pipValue)
   );
}
double MinDistancePoints(){
   return MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                  MarketInfo(Symbol(),MODE_FREEZELEVEL));
}
void AdjustDistances(double &slPoints,double &tpPoints){
   double minimum=MinDistancePoints();
   if(slPoints>0 && slPoints<minimum) slPoints=minimum;
   if(tpPoints>0 && tpPoints<minimum) tpPoints=minimum;
}

//--- signals
bool NewSignalBar(){
   datetime bar=iTime(Symbol(),InpTimeframe,1);
   if(bar<=0 || bar==lastSignalBar) return false;
   lastSignalBar=bar;
   return true;
}
bool HasBuyPullback(int tf,int firstShift,int lookback,double tolerance){
   for(int shift=firstShift;shift<firstShift+lookback;shift++){
      double fast=iMA(Symbol(),tf,FastEMA,0,MODE_EMA,PRICE_CLOSE,shift);
      double slow=iMA(Symbol(),tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE,shift);
      double low=iLow(Symbol(),tf,shift);
      double close=iClose(Symbol(),tf,shift);
      if(fast>slow && low<=fast+tolerance && close>=slow-tolerance) return true;
   }
   return false;
}
bool HasSellPullback(int tf,int firstShift,int lookback,double tolerance){
   for(int shift=firstShift;shift<firstShift+lookback;shift++){
      double fast=iMA(Symbol(),tf,FastEMA,0,MODE_EMA,PRICE_CLOSE,shift);
      double slow=iMA(Symbol(),tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE,shift);
      double high=iHigh(Symbol(),tf,shift);
      double close=iClose(Symbol(),tf,shift);
      if(fast<slow && high>=fast-tolerance && close<=slow+tolerance) return true;
   }
   return false;
}

//--- dataset helpers
string BuildParameterFingerprint(){
   string value="";
   value+="tf="+IntegerToString(InpTimeframe);
   value+="|fast="+IntegerToString(FastEMA)+"|slow="+IntegerToString(SlowEMA);
   value+="|rsi="+IntegerToString(RSIPeriod)+"|rsiLevel="+DoubleToString(RSIReclaimLevel,2);
   value+="|rsiBuffer="+DoubleToString(RSIMomentumBuffer,2);
   value+="|pullbackBars="+IntegerToString(PullbackLookbackBars);
   value+="|pullbackTolerance="+DoubleToString(PullbackTolerancePips,2);
   value+="|reclaimCandle="+BoolToken(RequireReclaimCandle);
   value+="|adxRising="+BoolToken(RequireADXRising);
   value+="|riskMode="+IntegerToString((int)LotMode);
   value+="|fixedLots="+DoubleToString(FixedLots,2);
   value+="|riskPct="+DoubleToString(RiskPercentPerTrade,3);
   value+="|sltpMode="+IntegerToString((int)SLTP_CalcMode);
   value+="|sl="+DoubleToString(SL_FixedPips,2)+"|tp="+DoubleToString(TP_FixedPips,2);
   value+="|atrPeriod="+IntegerToString(ATRPeriod);
   value+="|slAtr="+DoubleToString(SL_ATR_Mult,2)+"|tpAtr="+DoubleToString(TP_ATR_Mult,2);
   value+="|spread="+DoubleToString(MaxSpreadPips,2);
   value+="|spreadAtr="+DoubleToString(MaxSpreadATRRatio,3);
   value+="|minAtr="+DoubleToString(MinATR_Pips,2);
   value+="|sessions="+BoolToken(UseTokyo)+BoolToken(UseEurope)+BoolToken(UseNY);
   value+="|hours="+IntegerToString(TokyoStartHour)+"-"+IntegerToString(TokyoEndHour)+","+
          IntegerToString(EuropeStartHour)+"-"+IntegerToString(EuropeEndHour)+","+
          IntegerToString(NYStartHour)+"-"+IntegerToString(NYEndHour);
   value+="|adx="+IntegerToString(ADXPeriod)+","+DoubleToString(ADXThreshold,2);
   value+="|mtf="+BoolToken(UseMTF_Filter)+","+IntegerToString(MTF_Timeframe)+","+
          IntegerToString(MTF_MA_Period)+","+BoolToken(RequireMTFPriceAlignment);
   value+="|magic="+IntegerToString(MagicNumber);
   value+="|strategy="+StrategyVersion+"|feature="+FeatureSchemaVersion+"|label="+LabelVersion;
   return value;
}

bool BuildSignalFeatures(const int direction,
                         const datetime signalTime,
                         const double slPips,
                         const double tpPips,
                         const double atrPips,
                         const double previousAtrPips,
                         const double rsi,
                         const double adx,
                         const int h1Trend,
                         SignalFeatures &features){
   RefreshRates();
   if(Bid<=0 || Ask<=0 || atrPips<=0 || slPips<=0 || tpPips<=0) return false;

   double slPoints=PipToPoints(slPips);
   double tpPoints=PipToPoints(tpPips);
   AdjustDistances(slPoints,tpPoints);
   double entry=direction==OP_BUY ? Ask : Bid;
   double sl=direction==OP_BUY ? entry-slPoints*Point : entry+slPoints*Point;
   double tp=direction==OP_BUY ? entry+tpPoints*Point : entry-tpPoints*Point;

   int shift=1;
   double candleOpen=iOpen(Symbol(),InpTimeframe,shift);
   double candleHigh=iHigh(Symbol(),InpTimeframe,shift);
   double candleLow=iLow(Symbol(),InpTimeframe,shift);
   double candleClose=iClose(Symbol(),InpTimeframe,shift);
   if(candleOpen<=0 || candleHigh<=0 || candleLow<=0 || candleClose<=0) return false;

   features.signalTime=signalTime;
   features.signalEpoch=(long)signalTime;
   features.direction=direction;
   features.setupType="PULLBACK_RECLAIM";
   features.sessionTag=SessionTag(signalTime);
   features.bid=NormalizeDouble(Bid,Digits);
   features.ask=NormalizeDouble(Ask,Digits);
   features.spreadPips=SpreadPips();
   features.virtualEntryPrice=NormalizeDouble(entry,Digits);
   features.virtualSlPrice=NormalizeDouble(sl,Digits);
   features.virtualTpPrice=NormalizeDouble(tp,Digits);
   features.riskPips=PriceToPips(entry-sl);
   features.rewardPips=PriceToPips(tp-entry);
   features.atrPips=atrPips;
   features.atrChange=previousAtrPips>0 ? atrPips-previousAtrPips : EMPTY_VALUE;
   features.rsi=rsi;
   features.adx=adx;
   features.h1Trend=h1Trend;
   features.rangeWidthPips=EMPTY_VALUE;
   features.breakoutStrength=EMPTY_VALUE;
   features.bodyPips=PriceToPips(candleClose-candleOpen);
   features.upperWickPips=PriceToPips(candleHigh-MathMax(candleOpen,candleClose));
   features.lowerWickPips=PriceToPips(MathMin(candleOpen,candleClose)-candleLow);
   features.tickVolume=(long)iVolume(Symbol(),InpTimeframe,shift);

   return features.riskPips>0 && features.rewardPips>0 &&
          MathIsValidNumber(features.spreadPips) &&
          MathIsValidNumber(features.rsi) && MathIsValidNumber(features.adx);
}

void SetDecisionSkip(DecisionResult &decision,const string stage,const string reason){
   decision.eligible=false;
   decision.failedStage=stage;
   decision.reasonCode=reason;
   decision.finalDecision="SKIP";
}

void EvaluateDeterministicGuards(const SignalFeatures &features,DecisionResult &decision){
   ResetDecisionResult(decision);
   if(HasPosition()){
      SetDecisionSkip(decision,"POSITION","POSITION_EXISTS");
      return;
   }
   if(!TradingSession()){
      SetDecisionSkip(decision,"SESSION","SESSION_OFF");
      return;
   }
   if(!CooldownPassed()){
      SetDecisionSkip(decision,"COOLDOWN","COOLDOWN_ACTIVE");
      return;
   }
   if(MaxTradesPerDay>0 && TradesToday()>=MaxTradesPerDay){
      SetDecisionSkip(decision,"DAILY_LIMIT","MAX_TRADES_REACHED");
      return;
   }
   if(DailyLossReached()){
      SetDecisionSkip(decision,"DAILY_LIMIT","DAILY_LOSS_REACHED");
      return;
   }
   int losses=ConsecutiveLossesToday();
   if(MaxConsecLoss>0 && losses>=MaxConsecLoss){
      SetDecisionSkip(decision,"DAILY_LIMIT","CONSEC_LOSS_REACHED");
      return;
   }
   if(MinATR_Pips>0 && features.atrPips<MinATR_Pips){
      SetDecisionSkip(decision,"MARKET","ATR_TOO_LOW");
      return;
   }
   if(MaxSpreadPips>0 && features.spreadPips>MaxSpreadPips){
      SetDecisionSkip(decision,"MARKET","SPREAD_TOO_HIGH");
      return;
   }
   if(MaxSpreadATRRatio>0 && features.spreadPips/features.atrPips>MaxSpreadATRRatio){
      SetDecisionSkip(decision,"MARKET","SPREAD_ATR_TOO_HIGH");
      return;
   }
   double plannedLots=LotMode==FixedLot
      ? NormalizeLotsDown(FixedLots)
      : LotsByRisk(features.riskPips);
   if(plannedLots<=0){
      SetDecisionSkip(decision,"LOT","LOT_BELOW_MIN");
      return;
   }
}

//--- R-based exits. Initial risk is persisted in the order comment.
double InitialRiskPips(){
   string comment=OrderComment();
   int marker=StringFind(comment,"|R=");
   if(marker>=0){
      double stored=StrToDouble(StringSubstr(comment,marker+3));
      if(stored>0) return stored;
   }
   if(OrderStopLoss()<=0) return 0.0;
   return PriceToPips(OrderOpenPrice()-OrderStopLoss());
}
bool ModifyDistanceAllowed(int type,double newSL){
   double minimum=MinDistancePoints()*Point;
   if(type==OP_BUY) return newSL<Bid-minimum;
   if(type==OP_SELL) return newSL>Ask+minimum;
   return false;
}
void UpdateBreakEven(){
   if(!UseBreakEven) return;
   RefreshRates();
   for(int i=0;i<OrdersTotal();i++){
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      int type=OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;
      double risk=InitialRiskPips();
      if(risk<=0 || SignedProfitPips(type,OrderOpenPrice())<risk*BE_Trigger_R) continue;
      double newSL=type==OP_BUY
         ? OrderOpenPrice()+BE_Offset_Pips*PipSize()
         : OrderOpenPrice()-BE_Offset_Pips*PipSize();
      newSL=NormalizeDouble(newSL,Digits);
      bool improves=type==OP_BUY
         ? (OrderStopLoss()==0 || newSL>OrderStopLoss())
         : (OrderStopLoss()==0 || newSL<OrderStopLoss());
      if(!improves || !ModifyDistanceAllowed(type,newSL)) continue;
      ResetLastError();
      if(!OrderModify(OrderTicket(),OrderOpenPrice(),newSL,OrderTakeProfit(),0,clrGreen))
         Print("BreakEven modify failed. Err=",GetLastError());
   }
}
void UpdateTrailing(){
   if(!UseTrailing) return;
   RefreshRates();
   for(int i=0;i<OrdersTotal();i++){
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      int type=OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;
      double risk=InitialRiskPips();
      if(risk<=0 || SignedProfitPips(type,OrderOpenPrice())<risk*TrailStartR) continue;
      double distance=risk*TrailDistanceR;
      double newSL=type==OP_BUY ? Bid-distance*PipSize() : Ask+distance*PipSize();
      newSL=NormalizeDouble(newSL,Digits);
      double step=TrailStepPips*PipSize();
      bool improves=type==OP_BUY
         ? (OrderStopLoss()==0 || newSL>=OrderStopLoss()+step)
         : (OrderStopLoss()==0 || newSL<=OrderStopLoss()-step);
      if(!improves || !ModifyDistanceAllowed(type,newSL)) continue;
      ResetLastError();
      if(!OrderModify(OrderTicket(),OrderOpenPrice(),newSL,OrderTakeProfit(),0,clrAqua))
         Print("Trailing modify failed. Err=",GetLastError());
   }
}

//--- orders
int PlaceOrder(const int direction,
               const double slPips,
               const double tpPips,
               const string signalKey,
               int &orderError){
   orderError=0;
   if(slPips<=0 || tpPips<=0){
      orderError=130;
      return -1;
   }
   RefreshRates();
   double price=direction==OP_BUY ? Ask : Bid;
   double slPoints=PipToPoints(slPips);
   double tpPoints=PipToPoints(tpPips);
   AdjustDistances(slPoints,tpPoints);
   double sl=direction==OP_BUY ? price-slPoints*Point : price+slPoints*Point;
   double tp=direction==OP_BUY ? price+tpPoints*Point : price-tpPoints*Point;
   price=NormalizeDouble(price,Digits);
   sl=NormalizeDouble(sl,Digits);
   tp=NormalizeDouble(tp,Digits);
   double actualStop=PriceToPips(price-sl);
   double lots=LotMode==FixedLot ? NormalizeLotsDown(FixedLots) : LotsByRisk(actualStop);
   if(lots<=0){
      orderError=131;
      Print("Order rejected: invalid lots. stopPips=",DoubleToString(actualStop,2));
      return -1;
   }
   string comment="AI|"+signalKey+"|R="+DoubleToString(actualStop,2);
   ResetLastError();
   int ticket=OrderSend(Symbol(),direction,lots,price,SlippagePoints,
                        sl,tp,comment,MagicNumber,0,clrDodgerBlue);
   if(ticket<0){
      orderError=GetLastError();
      Print("OrderSend failed. Err=",orderError," lots=",DoubleToString(lots,2),
            " price=",DoubleToString(price,Digits));
      return -1;
   }
   lastEntryTime=TimeCurrent();
   GlobalVariableSet(gvLastEntryKey,(double)lastEntryTime);
   return ticket;
}

void ProcessSetup(const int direction,
                  const datetime signalTime,
                  const double slPips,
                  const double tpPips,
                  const double atrPips,
                  const double previousAtrPips,
                  const double rsi,
                  const double adx,
                  const int h1Trend){
   SignalFeatures features;
   if(!BuildSignalFeatures(direction,signalTime,slPips,tpPips,atrPips,previousAtrPips,
                           rsi,adx,h1Trend,features)){
      int errorCode=GetLastError();
      if(datasetLoggerReady)
         LogRuntimeError("FEATURE_BUILD","FEATURE_INVALID",errorCode,"","");
      return;
   }

   string signalId=AiCreateSignalId(direction,signalTime);
   string signalKey=AiCreateSignalKey(direction,signalTime);
   bool candidateLogged=!EnableDatasetLogging;
   if(EnableDatasetLogging && datasetLoggerReady){
      candidateLogged=LogSignalCandidate(signalId,signalKey,features,StrategyVersion,
                                         FeatureSchemaVersion,LabelVersion);
      if(!candidateLogged){
         int errorCode=GetLastError();
         LogRuntimeError("CANDIDATE","CANDIDATE_LOG_FAILED",errorCode,
                         "signal_candidates",signalId);
      }
   }

   DecisionResult decision;
   EvaluateDeterministicGuards(features,decision);

   if(decision.eligible){
      int orderError=0;
      int ticket=PlaceOrder(direction,slPips,tpPips,signalKey,orderError);
      decision.ticket=ticket;
      decision.orderError=orderError;
      if(ticket>0){
         decision.finalDecision="TRADE";
         decision.failedStage="ORDER";
         decision.reasonCode="ORDER_PLACED";
         if(datasetLoggerReady && OrderSelect(ticket,SELECT_BY_TICKET)){
            double stopPips=PriceToPips(OrderOpenPrice()-OrderStopLoss());
            double initialRiskMoney=stopPips*PipValuePerLot()*OrderLots();
            if(!AiRegisterTrade(signalId,signalKey,ticket,initialRiskMoney))
               LogRuntimeError("TRADE_REGISTER","TRADE_REGISTER_FAILED",GetLastError(),
                               "trade_results",signalId);
         }
         Print(AiDirectionName(direction)," pullback placed. SL=",DoubleToString(slPips,1),
               " TP=",DoubleToString(tpPips,1)," signal=",signalKey);
      }
      else{
         decision.finalDecision="ERROR";
         decision.failedStage="ORDER";
         decision.reasonCode="ORDER_SEND_FAILED";
      }
   }

   if(EnableDatasetLogging && datasetLoggerReady){
      if(!LogSignalDecision(signalId,signalKey,decision)){
         int errorCode=GetLastError();
         LogRuntimeError("DECISION","DECISION_LOG_FAILED",errorCode,
                         "signal_decisions",signalId);
      }
   }

   if(EnableDatasetLogging && !candidateLogged && DebugMode)
      Print("DBG: candidate was not persisted. signal=",signalKey);
}

//--- entry
void TryEntry(){
   if(!NewSignalBar()) return;

   int tf=InpTimeframe,now=1,prev=2;
   int required=(int)MathMax(MathMax(SlowEMA,ATRPeriod),MathMax(ADXPeriod,RSIPeriod))
      +PullbackLookbackBars+3;
   if(iBars(Symbol(),tf)<required) return;

   double atrPips=PriceToPips(iATR(Symbol(),tf,ATRPeriod,now));
   double previousAtrPips=PriceToPips(iATR(Symbol(),tf,ATRPeriod,prev));
   if(atrPips<=0) return;

   double fastNow=iMA(Symbol(),tf,FastEMA,0,MODE_EMA,PRICE_CLOSE,now);
   double slowNow=iMA(Symbol(),tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE,now);
   double openNow=iOpen(Symbol(),tf,now);
   double closeNow=iClose(Symbol(),tf,now);
   double closePrev=iClose(Symbol(),tf,prev);
   double rsiNow=iRSI(Symbol(),tf,RSIPeriod,PRICE_CLOSE,now);
   double rsiPrev=iRSI(Symbol(),tf,RSIPeriod,PRICE_CLOSE,prev);
   double adxNow=iADX(Symbol(),tf,ADXPeriod,PRICE_CLOSE,MODE_MAIN,now);
   double adxPrev=iADX(Symbol(),tf,ADXPeriod,PRICE_CLOSE,MODE_MAIN,prev);
   if(adxNow<ADXThreshold) return;
   if(RequireADXRising && adxNow<=adxPrev) return;

   double tolerance=PullbackTolerancePips*PipSize();
   bool buyPullback=HasBuyPullback(tf,prev,PullbackLookbackBars,tolerance);
   bool sellPullback=HasSellPullback(tf,prev,PullbackLookbackBars,tolerance);
   double buyRsiThreshold=RSIReclaimLevel+RSIMomentumBuffer;
   double sellRsiThreshold=RSIReclaimLevel-RSIMomentumBuffer;

   bool buy=fastNow>slowNow && buyPullback &&
            closeNow>fastNow && closeNow>closePrev &&
            rsiNow>=buyRsiThreshold && rsiNow>rsiPrev;
   bool sell=fastNow<slowNow && sellPullback &&
             closeNow<fastNow && closeNow<closePrev &&
             rsiNow<=sellRsiThreshold && rsiNow<rsiPrev;

   if(RequireReclaimCandle){
      if(closeNow<=openNow) buy=false;
      if(closeNow>=openNow) sell=false;
   }

   int h1Trend=0;
   if(UseMTF_Filter){
      if(iBars(Symbol(),MTF_Timeframe)<MTF_MA_Period+3) return;
      double mtfNow=iMA(Symbol(),MTF_Timeframe,MTF_MA_Period,0,MODE_EMA,PRICE_CLOSE,1);
      double mtfPrev=iMA(Symbol(),MTF_Timeframe,MTF_MA_Period,0,MODE_EMA,PRICE_CLOSE,2);
      double mtfClose=iClose(Symbol(),MTF_Timeframe,1);
      if(mtfNow>mtfPrev) h1Trend=1;
      else if(mtfNow<mtfPrev) h1Trend=-1;
      if(mtfNow<=mtfPrev) buy=false;
      if(mtfNow>=mtfPrev) sell=false;
      if(RequireMTFPriceAlignment){
         if(mtfClose<=mtfNow) buy=false;
         if(mtfClose>=mtfNow) sell=false;
      }
   }

   if(!buy && !sell) return;

   double slPips=SL_FixedPips,tpPips=TP_FixedPips;
   if(SLTP_CalcMode==UseATR){
      slPips=atrPips*SL_ATR_Mult;
      tpPips=atrPips*TP_ATR_Mult;
   }

   datetime signalTime=iTime(Symbol(),tf,0);
   if(signalTime<=0) signalTime=TimeCurrent();
   if(buy)
      ProcessSetup(OP_BUY,signalTime,slPips,tpPips,atrPips,previousAtrPips,rsiNow,adxNow,h1Trend);
   else if(sell)
      ProcessSetup(OP_SELL,signalTime,slPips,tpPips,atrPips,previousAtrPips,rsiNow,adxNow,h1Trend);
}

bool ValidHour(int value){ return value>=0 && value<=23; }
int OnInit(){
   bool invalid=FastEMA<=0 || SlowEMA<=0 || FastEMA>=SlowEMA ||
      RSIPeriod<=0 || RSIReclaimLevel<=0 || RSIReclaimLevel>=100 ||
      RSIMomentumBuffer<0 || RSIReclaimLevel+RSIMomentumBuffer>=100 ||
      RSIReclaimLevel-RSIMomentumBuffer<=0 || PullbackLookbackBars<=0 ||
      PullbackTolerancePips<0 || ATRPeriod<=0 || ADXPeriod<=0 || MTF_MA_Period<=0 ||
      SL_FixedPips<=0 || TP_FixedPips<=0 || SL_ATR_Mult<=0 || TP_ATR_Mult<=0 ||
      FixedLots<0 || RiskPercentPerTrade<0 || MaxSpreadPips<0 ||
      MaxSpreadATRRatio<0 || MinATR_Pips<0 || MaxDailyLossPercent<0 ||
      BE_Trigger_R<=0 || BE_Offset_Pips<0 || TrailStartR<=0 ||
      TrailDistanceR<=0 || TrailStepPips<0 || LogFlushEveryN<=0 ||
      StringLen(FeatureSchemaVersion)==0 || StringLen(LabelVersion)==0 ||
      StringLen(StrategyVersion)==0 ||
      !ValidHour(TokyoStartHour) || !ValidHour(TokyoEndHour) ||
      !ValidHour(EuropeStartHour) || !ValidHour(EuropeEndHour) ||
      !ValidHour(NYStartHour) || !ValidHour(NYEndHour);
   if(invalid) return INIT_PARAMETERS_INCORRECT;
   if(LotMode==FixedLot && FixedLots<=0) return INIT_PARAMETERS_INCORRECT;
   if(LotMode==RiskPercent && RiskPercentPerTrade<=0) return INIT_PARAMETERS_INCORRECT;
   if(StringFind(Symbol(),"USDJPY")<0)
      Print("Warning: designed for USDJPY. Current symbol=",Symbol());

   gvLastEntryKey=StringFormat("GV_LASTENTRY_%s_%d",Symbol(),MagicNumber);
   if(IsTesting() && GlobalVariableCheck(gvLastEntryKey)) GlobalVariableDel(gvLastEntryKey);
   lastSignalBar=0;

   AiInitializeRunContext(InpTimeframe,(int)MarketInfo(Symbol(),MODE_SPREAD),
                          BuildParameterFingerprint());
   if(EnableDatasetLogging){
      datasetLoggerReady=AiLoggerInitialize(gAiRunId,LogFlushEveryN);
      if(datasetLoggerReady){
         string spreadMode=IsTesting()
            ? "TESTER_"+IntegerToString((int)MarketInfo(Symbol(),MODE_SPREAD))+"PT"
            : "CURRENT";
         if(!AiWriteRunManifest(gAiRunId,AiDataSource(),TimeCurrent(),InpTimeframe,
                                EA_VERSION,StrategyVersion,FeatureSchemaVersion,LabelVersion,
                                gAiParameterHash,spreadMode)){
            int errorCode=GetLastError();
            LogRuntimeError("MANIFEST","MANIFEST_LOG_FAILED",errorCode,
                            "run_manifest","");
         }
      }
      else{
         Print("Warning: dataset logging is unavailable; trading continues in AI OFF mode.");
      }
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
   if(datasetLoggerReady){
      AiUpdateTrackedTrades(PipSize());
      AiLoggerShutdown();
      datasetLoggerReady=false;
   }
}

void OnTick(){
   if(datasetLoggerReady) AiUpdateTrackedTrades(PipSize());
   UpdateBreakEven();
   UpdateTrailing();
   TryEntry();
}
