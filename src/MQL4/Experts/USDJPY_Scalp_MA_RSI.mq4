//+------------------------------------------------------------------+
//| USDJPY_Scalp_MA_RSI.mq4                                         |
//| Logic A: 5EMA/20EMA + RSI filter (Rakuten MT4 tuned)            |
//+------------------------------------------------------------------+
#property strict

input int InpTimeframe=PERIOD_M5;
input int FastEMA=5;
input int SlowEMA=20;
input int RSIPeriod=14;
input int RSI_Level_Buy=55;
input int RSI_Level_Sell=45;

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

datetime lastEntryTime=0;
datetime lastSignalBar=0;
string gvLastEntryKey="";

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
   double tickSizePoints=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickValue<=0 || tickSizePoints<=0) return 0.0;
   return tickValue*PipToPoints(1.0)/tickSizePoints;
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
bool CrossUp(double fp,double sp,double fn,double sn){ return fp<=sp && fn>sn; }
bool CrossDown(double fp,double sp,double fn,double sn){ return fp>=sp && fn<sn; }
bool NewSignalBar(){
   datetime bar=iTime(Symbol(),InpTimeframe,1);
   if(bar<=0 || bar==lastSignalBar) return false;
   lastSignalBar=bar;
   return true;
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
bool PlaceOrder(int direction,double slPips,double tpPips){
   if(slPips<=0 || tpPips<=0) return false;
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
      Print("Order rejected: invalid lots. stopPips=",DoubleToString(actualStop,2));
      return false;
   }
   string comment="MA-RSI|R="+DoubleToString(actualStop,2);
   ResetLastError();
   int ticket=OrderSend(Symbol(),direction,lots,price,SlippagePoints,
                        sl,tp,comment,MagicNumber,0,clrDodgerBlue);
   if(ticket<0){
      Print("OrderSend failed. Err=",GetLastError()," lots=",DoubleToString(lots,2),
            " price=",DoubleToString(price,Digits));
      return false;
   }
   lastEntryTime=TimeCurrent();
   GlobalVariableSet(gvLastEntryKey,(double)lastEntryTime);
   return true;
}

//--- entry
void TryEntry(){
   if(!NewSignalBar() || HasPosition() || !TradingSession() || !CooldownPassed()) return;
   if(MaxTradesPerDay>0 && TradesToday()>=MaxTradesPerDay) return;
   if(DailyLossReached()) return;
   int losses=ConsecutiveLossesToday();
   if(MaxConsecLoss>0 && losses>=MaxConsecLoss){
      Print("Consecutive loss cap reached: ",losses);
      return;
   }

   int tf=InpTimeframe,now=1,prev=2;
   int required=(int)MathMax(MathMax(SlowEMA,ATRPeriod),MathMax(ADXPeriod,RSIPeriod))+3;
   if(iBars(Symbol(),tf)<required) return;

   double atrPips=PriceToPips(iATR(Symbol(),tf,ATRPeriod,now));
   if(atrPips<=0) return;
   if(MinATR_Pips>0 && atrPips<MinATR_Pips) return;
   double spread=SpreadPips();
   if(MaxSpreadPips>0 && spread>MaxSpreadPips) return;
   if(MaxSpreadATRRatio>0 && spread/atrPips>MaxSpreadATRRatio) return;

   double fastNow=iMA(Symbol(),tf,FastEMA,0,MODE_EMA,PRICE_CLOSE,now);
   double slowNow=iMA(Symbol(),tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE,now);
   double fastPrev=iMA(Symbol(),tf,FastEMA,0,MODE_EMA,PRICE_CLOSE,prev);
   double slowPrev=iMA(Symbol(),tf,SlowEMA,0,MODE_EMA,PRICE_CLOSE,prev);
   double rsi=iRSI(Symbol(),tf,RSIPeriod,PRICE_CLOSE,now);
   double closePrice=iClose(Symbol(),tf,now);
   double adx=iADX(Symbol(),tf,ADXPeriod,PRICE_CLOSE,MODE_MAIN,now);
   if(adx<ADXThreshold) return;

   double slPips=SL_FixedPips,tpPips=TP_FixedPips;
   if(SLTP_CalcMode==UseATR){
      slPips=atrPips*SL_ATR_Mult;
      tpPips=atrPips*TP_ATR_Mult;
   }

   bool buy=closePrice>slowNow && CrossUp(fastPrev,slowPrev,fastNow,slowNow) &&
            rsi>RSI_Level_Buy;
   bool sell=closePrice<slowNow && CrossDown(fastPrev,slowPrev,fastNow,slowNow) &&
             rsi<RSI_Level_Sell;

   if(UseMTF_Filter){
      if(iBars(Symbol(),MTF_Timeframe)<MTF_MA_Period+3) return;
      double mtfNow=iMA(Symbol(),MTF_Timeframe,MTF_MA_Period,0,MODE_EMA,PRICE_CLOSE,1);
      double mtfPrev=iMA(Symbol(),MTF_Timeframe,MTF_MA_Period,0,MODE_EMA,PRICE_CLOSE,2);
      if(mtfNow<=mtfPrev) buy=false;
      if(mtfNow>=mtfPrev) sell=false;
   }

   if(buy && PlaceOrder(OP_BUY,slPips,tpPips))
      Print("BUY placed. SL=",DoubleToString(slPips,1)," TP=",DoubleToString(tpPips,1));
   else if(sell && PlaceOrder(OP_SELL,slPips,tpPips))
      Print("SELL placed. SL=",DoubleToString(slPips,1)," TP=",DoubleToString(tpPips,1));
}

bool ValidHour(int value){ return value>=0 && value<=23; }
int OnInit(){
   bool invalid=FastEMA<=0 || SlowEMA<=0 || FastEMA>=SlowEMA ||
      RSIPeriod<=0 || ATRPeriod<=0 || ADXPeriod<=0 || MTF_MA_Period<=0 ||
      SL_FixedPips<=0 || TP_FixedPips<=0 || SL_ATR_Mult<=0 || TP_ATR_Mult<=0 ||
      FixedLots<0 || RiskPercentPerTrade<0 || MaxSpreadPips<0 ||
      MaxSpreadATRRatio<0 || MinATR_Pips<0 || MaxDailyLossPercent<0 ||
      BE_Trigger_R<=0 || BE_Offset_Pips<0 || TrailStartR<=0 ||
      TrailDistanceR<=0 || TrailStepPips<0 ||
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
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){}
void OnTick(){
   UpdateBreakEven();
   UpdateTrailing();
   TryEntry();
}
