//+------------------------------------------------------------------+
//|  USDJPY_Scalp_MA_RSI.mq4                                         |
//|  Logic A: 5EMA/20EMA + RSI filter (Rakuten MT4 tuned)            |
//+------------------------------------------------------------------+
#property strict

input int    InpTimeframe          = PERIOD_M5;
input int    FastEMA               = 5;
input int    SlowEMA               = 20;
input int    RSIPeriod             = 14;
input int    RSI_Level_Buy         = 55;
input int    RSI_Level_Sell        = 45;

enum RiskMode { FixedLot=0, RiskPercent=1 };
input RiskMode LotMode             = RiskPercent;
input double   FixedLots           = 0.10;
input double   RiskPercentPerTrade = 1.0;

enum SLTPMode { UseFixed=0, UseATR=1 };
input SLTPMode SLTP_CalcMode       = UseFixed;
input double   SL_FixedPips        = 6.0;
input double   TP_FixedPips        = 9.0;
input int      ATRPeriod           = 14;
input double   SL_ATR_Mult         = 1.0;
input double   TP_ATR_Mult         = 1.5;

input bool     UseTrailing         = true;
input double   TrailStartPips      = 5.0;
input double   TrailStepPips       = 1.0;

input bool     UseBreakEven        = true;
input double   BE_Trigger_Mult     = 0.5;
input double   BE_Offset_Pips      = 0.5;

input double   MaxSpreadPips       = 1.5;
input int      SlippagePoints      = 3;
input int      CooldownMinutes     = 5;
input int      MaxTradesPerDay     = 20;
input int      MaxConsecLoss       = 3;

input bool     UseTokyo            = false;
input bool     UseEurope           = false;
input bool     UseNY               = false;
input bool     UseManualSessionFilter = false;
input string   ManualSessionRanges = "";

input bool     DebugMode           = true;
input double   MinATR_Pips         = 0.0;

input int      MagicNumber         = 20251101;

input int      ADXPeriod           = 14;
input int      ADXThreshold        = 20;

input bool     UseMTF_Filter       = true;
input int      MTF_Timeframe       = 60;
input int      MTF_MA_Period       = 20;

datetime lastEntryTime = 0;
datetime lastSignalBar = 0;
string   gvLastEntryKey;

//+------------------------------------------------------------------+
// pips/points conversion for JPY pairs.
// 1 pip for USDJPY is 0.01 yen.
//+------------------------------------------------------------------+
double PipToPoints(double pips){
   double pipSize = 0.01;
   double pointsPerPip = pipSize / Point;
   return pips * pointsPerPip;
}

double PointsToPips(double points){
   double pipSize = 0.01;
   double pointsPerPip = pipSize / Point;
   return points / pointsPerPip;
}

double GetSpreadPips(){
   double spreadPoints = (double)MarketInfo(Symbol(), MODE_SPREAD);
   return PointsToPips(spreadPoints);
}

string TrimString(string text){
   return StringTrimRight(StringTrimLeft(text));
}

bool ParseTimeToMinutes(string text, int &minutes){
   text = TrimString(text);
   int sep = StringFind(text, ":");
   if(sep <= 0) return false;

   string hStr = StringSubstr(text, 0, sep);
   string mStr = StringSubstr(text, sep + 1);
   int h = (int)StrToInteger(hStr);
   int m = (int)StrToInteger(mStr);

   if(h < 0 || h > 23 || m < 0 || m > 59) return false;

   minutes = h * 60 + m;
   return true;
}

bool IsWithinManualSessions(){
   if(!UseManualSessionFilter) return true;

   string ranges = ManualSessionRanges;
   if(StringLen(ranges) == 0) return true;

   datetime now = TimeCurrent();
   int curMinutes = TimeHour(now) * 60 + TimeMinute(now);

   string entries[];
   ushort delim = ';';
   int count = StringSplit(ranges, delim, entries);
   if(count <= 0) return true;

   for(int i = 0; i < count; i++){
      string token = TrimString(entries[i]);
      if(StringLen(token) == 0) continue;

      int dash = StringFind(token, "-");
      if(dash <= 0) continue;

      string startStr = StringSubstr(token, 0, dash);
      string endStr   = StringSubstr(token, dash + 1);
      int startMin = 0;
      int endMin = 0;

      if(!ParseTimeToMinutes(startStr, startMin) ||
         !ParseTimeToMinutes(endStr, endMin)){
         continue;
      }

      if(endMin < startMin){
         if(curMinutes >= startMin || curMinutes <= endMin) return true;
      }else{
         if(curMinutes >= startMin && curMinutes <= endMin) return true;
      }
   }

   return false;
}

bool IsTradingSession(){
   if(!IsWithinManualSessions()){
      if(DebugMode) Print("DBG: manual session filter off");
      return false;
   }

   if(!UseTokyo && !UseEurope && !UseNY) return true;

   int hour = TimeHour(TimeCurrent());
   bool tokyo  = (hour >= 2  && hour < 10);
   bool europe = (hour >= 9  && hour < 18);
   bool ny     = (hour >= 14 && hour <= 23);

   bool allowed =
      (UseTokyo && tokyo) ||
      (UseEurope && europe) ||
      (UseNY && ny);

   if(!allowed && DebugMode) Print("DBG: session off");
   return allowed;
}

bool CooldownPassed(int &remainSeconds){
   datetime t = lastEntryTime;

   if(t == 0){
      if(gvLastEntryKey == ""){
         gvLastEntryKey =
            StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
      }

      if(GlobalVariableCheck(gvLastEntryKey)){
         t = (datetime)GlobalVariableGet(gvLastEntryKey);
         lastEntryTime = t;
      }
   }

   if(t == 0 || t > TimeCurrent()){
      remainSeconds = 0;
      return true;
   }

   int elapsed = (int)(TimeCurrent() - t);
   int cooldown = CooldownMinutes * 60;

   if(elapsed >= cooldown){
      remainSeconds = 0;
      return true;
   }

   remainSeconds = cooldown - elapsed;
   if(remainSeconds < 0) remainSeconds = 0;
   return false;
}

bool CooldownPassed(){
   int remainSeconds = 0;
   return CooldownPassed(remainSeconds);
}

int TradesTodayCount(){
   int count = 0;
   datetime dayStart =
      StrToTime(TimeToString(TimeCurrent(), TIME_DATE));

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() ||
         OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderOpenTime() >= dayStart) count++;
   }

   for(int j = 0; j < OrdersTotal(); j++){
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() ||
         OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderOpenTime() >= dayStart) count++;
   }

   return count;
}

// Count only the most recent consecutive losses closed today.
// Explicit close-time ordering avoids relying on history display order.
int ConsecutiveLossesToday(){
   int consec = 0;
   datetime dayStart =
      StrToTime(TimeToString(TimeCurrent(), TIME_DATE));

   datetime beforeCloseTime = TimeCurrent() + 1;
   int beforeTicket = 2147483647;

   while(true){
      bool found = false;
      datetime latestCloseTime = 0;
      int latestTicket = -1;
      double latestProfit = 0.0;

      for(int i = OrdersHistoryTotal() - 1; i >= 0; i--){
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
         if(OrderSymbol() != Symbol() ||
            OrderMagicNumber() != MagicNumber) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

         datetime closeTime = OrderCloseTime();
         int ticket = OrderTicket();

         if(closeTime < dayStart) continue;
         if(closeTime > beforeCloseTime) continue;
         if(closeTime == beforeCloseTime && ticket >= beforeTicket) continue;

         if(!found ||
            closeTime > latestCloseTime ||
            (closeTime == latestCloseTime && ticket > latestTicket)){
            found = true;
            latestCloseTime = closeTime;
            latestTicket = ticket;
            latestProfit =
               OrderProfit() +
               OrderSwap() +
               OrderCommission();
         }
      }

      if(!found) break;

      if(latestProfit < 0){
         consec++;
      }else if(latestProfit > 0){
         break;
      }

      beforeCloseTime = latestCloseTime;
      beforeTicket = latestTicket;
   }

   return consec;
}

bool HasOpenPosition(){
   for(int i = 0; i < OrdersTotal(); i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;

      if(OrderSymbol() == Symbol() &&
         OrderMagicNumber() == MagicNumber &&
         (OrderType() == OP_BUY || OrderType() == OP_SELL)){
         return true;
      }
   }

   return false;
}

double PipValuePerLot(){
   return MarketInfo(Symbol(), MODE_TICKVALUE) * PipToPoints(1.0);
}

int LotDigitsFromStep(double step){
   int digits = 0;

   while(digits < 8 &&
         MathAbs(step - NormalizeDouble(step, digits)) > 0.00000001){
      digits++;
   }

   return digits;
}

double NormalizeLotsDown(double lots){
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(minLot <= 0 || maxLot <= 0 || step <= 0) return 0.0;

   lots = MathMin(lots, maxLot);
   lots = MathFloor((lots + 0.00000001) / step) * step;

   if(lots < minLot) return 0.0;

   return NormalizeDouble(lots, LotDigitsFromStep(step));
}

double CalcLotsByRisk(double stopPips){
   if(stopPips <= 0 || RiskPercentPerTrade <= 0) return 0.0;

   double riskMoney =
      AccountBalance() * (RiskPercentPerTrade / 100.0);
   double pipValue1Lot = PipValuePerLot();

   if(riskMoney <= 0 || pipValue1Lot <= 0) return 0.0;

   double rawLots =
      riskMoney / (stopPips * pipValue1Lot);
   double lots = NormalizeLotsDown(rawLots);

   if(lots <= 0 && DebugMode){
      Print(
         "DBG: risk lot rejected. rawLots=",
         DoubleToString(rawLots, 4),
         " stopPips=",
         DoubleToString(stopPips, 2)
      );
   }

   return lots;
}

void AdjustSLTPForBroker(double &slPoints, double &tpPoints){
   double stopLevelPts   = MarketInfo(Symbol(), MODE_STOPLEVEL);
   double freezeLevelPts = MarketInfo(Symbol(), MODE_FREEZELEVEL);
   double minDist = MathMax(stopLevelPts, freezeLevelPts);

   if(slPoints > 0 && slPoints < minDist) slPoints = minDist;
   if(tpPoints > 0 && tpPoints < minDist) tpPoints = minDist;
}

bool CrossUp(
   double fastPrev,
   double slowPrev,
   double fastNow,
   double slowNow
){
   return fastPrev <= slowPrev && fastNow > slowNow;
}

bool CrossDown(
   double fastPrev,
   double slowPrev,
   double fastNow,
   double slowNow
){
   return fastPrev >= slowPrev && fastNow < slowNow;
}

// Evaluate each completed signal bar exactly once.
bool IsNewSignalBar(){
   datetime signalBar =
      iTime(Symbol(), InpTimeframe, 1);

   if(signalBar <= 0 || signalBar == lastSignalBar){
      return false;
   }

   lastSignalBar = signalBar;
   return true;
}

void UpdateTrailingStops(){
   if(!UseTrailing) return;

   RefreshRates();

   for(int i = 0; i < OrdersTotal(); i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() ||
         OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL) continue;

      double open = OrderOpenPrice();
      double profitPips = 0.0;

      if(type == OP_BUY){
         profitPips =
            PointsToPips((Bid - open) / Point);
      }else{
         profitPips =
            PointsToPips((open - Ask) / Point);
      }

      // Signed profit prevents trailing from activating in a loss.
      if(profitPips < TrailStartPips) continue;

      double currentSL = OrderStopLoss();
      double trailPts = PipToPoints(TrailStepPips);

      if(type == OP_BUY){
         double slDistancePts = trailPts;
         double unusedTpPts = 0.0;
         AdjustSLTPForBroker(slDistancePts, unusedTpPts);

         double candidateSL =
            NormalizeDouble(
               Bid - slDistancePts * Point,
               Digits
            );

         if((currentSL == 0 || candidateSL > currentSL) &&
            candidateSL < Bid){
            ResetLastError();

            if(!OrderModify(
               OrderTicket(),
               OrderOpenPrice(),
               candidateSL,
               OrderTakeProfit(),
               0,
               clrAqua
            )){
               Print(
                  "OrderModify trailing BUY failed. Err=",
                  GetLastError()
               );
            }
         }
      }else{
         double slDistancePts = trailPts;
         double unusedTpPts = 0.0;
         AdjustSLTPForBroker(slDistancePts, unusedTpPts);

         double candidateSL =
            NormalizeDouble(
               Ask + slDistancePts * Point,
               Digits
            );

         if((currentSL == 0 || candidateSL < currentSL) &&
            candidateSL > Ask){
            ResetLastError();

            if(!OrderModify(
               OrderTicket(),
               OrderOpenPrice(),
               candidateSL,
               OrderTakeProfit(),
               0,
               clrAqua
            )){
               Print(
                  "OrderModify trailing SELL failed. Err=",
                  GetLastError()
               );
            }
         }
      }
   }
}

void UpdateBreakEven(){
   if(!UseBreakEven) return;

   for(int i = 0; i < OrdersTotal(); i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() ||
         OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      double openPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double takeProfit = OrderTakeProfit();

      if(takeProfit == 0) continue;

      if(type == OP_BUY){
         double targetDist = takeProfit - openPrice;
         double currentDist = Bid - openPrice;

         if(currentDist >= targetDist * BE_Trigger_Mult){
            double newSL =
               NormalizeDouble(
                  openPrice +
                  PipToPoints(BE_Offset_Pips) * Point,
                  Digits
               );

            if(newSL > currentSL && newSL < Bid){
               if(!OrderModify(
                  OrderTicket(),
                  openPrice,
                  newSL,
                  takeProfit,
                  0,
                  clrGreen
               )){
                  Print(
                     "BreakEven modify failed. Err=",
                     GetLastError()
                  );
               }
            }
         }
      }else if(type == OP_SELL){
         double targetDist = openPrice - takeProfit;
         double currentDist = openPrice - Ask;

         if(currentDist >= targetDist * BE_Trigger_Mult){
            double newSL =
               NormalizeDouble(
                  openPrice -
                  PipToPoints(BE_Offset_Pips) * Point,
                  Digits
               );

            if((currentSL == 0 || newSL < currentSL) &&
               newSL > Ask){
               if(!OrderModify(
                  OrderTicket(),
                  openPrice,
                  newSL,
                  takeProfit,
                  0,
                  clrGreen
               )){
                  Print(
                     "BreakEven modify failed. Err=",
                     GetLastError()
                  );
               }
            }
         }
      }
   }
}

bool PlaceOrder(int direction, double slPips, double tpPips){
   RefreshRates();

   double price =
      direction == OP_BUY ? Ask : Bid;
   double slPts = PipToPoints(slPips);
   double tpPts = PipToPoints(tpPips);

   AdjustSLTPForBroker(slPts, tpPts);

   double sl = 0.0;
   double tp = 0.0;

   if(direction == OP_BUY){
      if(slPts > 0) sl = price - slPts * Point;
      if(tpPts > 0) tp = price + tpPts * Point;
   }else{
      if(slPts > 0) sl = price + slPts * Point;
      if(tpPts > 0) tp = price - tpPts * Point;
   }

   price = NormalizeDouble(price, Digits);
   if(sl > 0) sl = NormalizeDouble(sl, Digits);
   if(tp > 0) tp = NormalizeDouble(tp, Digits);

   // Risk sizing must use the actual broker-adjusted stop distance.
   double actualStopPips = 0.0;
   if(sl > 0){
      actualStopPips =
         PointsToPips(MathAbs(price - sl) / Point);
   }

   double lots = 0.0;

   if(LotMode == FixedLot){
      lots = NormalizeLotsDown(FixedLots);
   }else{
      lots = CalcLotsByRisk(actualStopPips);
   }

   if(lots <= 0){
      Print(
         "Order rejected: invalid lot size. actualStopPips=",
         DoubleToString(actualStopPips, 2)
      );
      return false;
   }

   ResetLastError();

   int ticket = OrderSend(
      Symbol(),
      direction,
      lots,
      price,
      SlippagePoints,
      sl,
      tp,
      "MA-RSI",
      MagicNumber,
      0,
      clrDodgerBlue
   );

   if(ticket < 0){
      Print(
         "OrderSend failed. Err=",
         GetLastError(),
         " lots=",
         DoubleToString(lots, 2),
         " price=",
         DoubleToString(price, Digits),
         " sl=",
         DoubleToString(sl, Digits),
         " tp=",
         DoubleToString(tp, Digits)
      );
      return false;
   }

   lastEntryTime = TimeCurrent();

   if(gvLastEntryKey == ""){
      gvLastEntryKey =
         StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
   }

   GlobalVariableSet(
      gvLastEntryKey,
      (double)lastEntryTime
   );

   return true;
}

void TryEntry(){
   // Position management remains tick-based, but entries are evaluated
   // once per completed InpTimeframe bar.
   if(!IsNewSignalBar()) return;

   if(HasOpenPosition()) return;
   if(!IsTradingSession()) return;
   if(!CooldownPassed()) return;

   if(MaxTradesPerDay > 0 &&
      TradesTodayCount() >= MaxTradesPerDay){
      return;
   }

   int consec = ConsecutiveLossesToday();

   if(MaxConsecLoss > 0 &&
      consec >= MaxConsecLoss){
      Print(
         "Consecutive loss cap reached (Today: ",
         consec,
         ")"
      );
      return;
   }

   double spread = GetSpreadPips();

   if(spread > MaxSpreadPips){
      if(DebugMode){
         Print(
            "Spread too wide: ",
            DoubleToString(spread, 1),
            " pips"
         );
      }
      return;
   }

   int tf = InpTimeframe;
   int shiftNow = 1;
   int shiftPrev = 2;

   int requiredBars =
      (int)MathMax(
         MathMax(SlowEMA, ATRPeriod),
         MathMax(ADXPeriod, RSIPeriod)
      ) + shiftPrev + 1;

   if(iBars(Symbol(), tf) < requiredBars) return;

   double fastNow =
      iMA(
         Symbol(), tf, FastEMA, 0,
         MODE_EMA, PRICE_CLOSE, shiftNow
      );
   double slowNow =
      iMA(
         Symbol(), tf, SlowEMA, 0,
         MODE_EMA, PRICE_CLOSE, shiftNow
      );
   double fastPrev =
      iMA(
         Symbol(), tf, FastEMA, 0,
         MODE_EMA, PRICE_CLOSE, shiftPrev
      );
   double slowPrev =
      iMA(
         Symbol(), tf, SlowEMA, 0,
         MODE_EMA, PRICE_CLOSE, shiftPrev
      );
   double rsiNow =
      iRSI(
         Symbol(), tf, RSIPeriod,
         PRICE_CLOSE, shiftNow
      );
   double closeNow =
      iClose(Symbol(), tf, shiftNow);

   double adx =
      iADX(
         Symbol(), tf, ADXPeriod,
         PRICE_CLOSE, MODE_MAIN, shiftNow
      );

   if(adx < ADXThreshold) return;

   double SLp = SL_FixedPips;
   double TPp = TP_FixedPips;

   if(SLTP_CalcMode == UseATR){
      double atrPoints =
         iATR(
            Symbol(), tf, ATRPeriod, shiftNow
         ) / Point;
      double atrPips = PointsToPips(atrPoints);

      SLp = atrPips * SL_ATR_Mult;
      TPp = atrPips * TP_ATR_Mult;
   }

   bool longCond =
      closeNow > slowNow &&
      CrossUp(
         fastPrev,
         slowPrev,
         fastNow,
         slowNow
      ) &&
      rsiNow > RSI_Level_Buy;

   bool shortCond =
      closeNow < slowNow &&
      CrossDown(
         fastPrev,
         slowPrev,
         fastNow,
         slowNow
      ) &&
      rsiNow < RSI_Level_Sell;

   if(UseMTF_Filter){
      double mtfMaNow =
         iMA(
            Symbol(),
            MTF_Timeframe,
            MTF_MA_Period,
            0,
            MODE_EMA,
            PRICE_CLOSE,
            1
         );
      double mtfMaPrev =
         iMA(
            Symbol(),
            MTF_Timeframe,
            MTF_MA_Period,
            0,
            MODE_EMA,
            PRICE_CLOSE,
            2
         );

      bool isUptrend = mtfMaNow > mtfMaPrev;
      bool isDowntrend = mtfMaNow < mtfMaPrev;

      if(!isUptrend) longCond = false;
      if(!isDowntrend) shortCond = false;
   }

   if(longCond){
      if(PlaceOrder(OP_BUY, SLp, TPp)){
         Print(
            "BUY placed. SL=",
            DoubleToString(SLp, 1),
            " TP=",
            DoubleToString(TPp, 1),
            " ADX=",
            DoubleToString(adx, 1)
         );
      }
   }else if(shortCond){
      if(PlaceOrder(OP_SELL, SLp, TPp)){
         Print(
            "SELL placed. SL=",
            DoubleToString(SLp, 1),
            " TP=",
            DoubleToString(TPp, 1),
            " ADX=",
            DoubleToString(adx, 1)
         );
      }
   }
}

int OnInit(){
   gvLastEntryKey =
      StringFormat(
         "GV_LASTENTRY_%s_%d",
         Symbol(),
         MagicNumber
      );

   if(IsTesting() &&
      GlobalVariableCheck(gvLastEntryKey)){
      GlobalVariableDel(gvLastEntryKey);
   }

   lastSignalBar = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
}

void OnTick(){
   UpdateTrailingStops();
   UpdateBreakEven();
   TryEntry();
}
