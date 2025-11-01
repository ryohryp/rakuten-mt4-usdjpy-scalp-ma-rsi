//+------------------------------------------------------------------+
//|  USDJPY_Scalp_MA_RSI.mq4                                         |
//|  Logic A: 5EMA/20EMA + RSI filter (Rakuten MT4 tuned)            |
//+------------------------------------------------------------------+
#property strict

input int    InpTimeframe        = PERIOD_M5;
input int    FastEMA             = 5;
input int    SlowEMA             = 20;
input int    RSIPeriod           = 14;
input double RSIThreshMid        = 50.0;

enum RiskMode { FixedLot=0, RiskPercent=1 };
input RiskMode LotMode           = RiskPercent;
input double   FixedLots         = 0.10;     // 固定ロット時
input double   RiskPercentPerTrade = 1.0;    // リスク％（例：1%）

enum SLTPMode { UseFixed=0, UseATR=1 };
input SLTPMode SLTP_CalcMode     = UseFixed;
input double   SL_FixedPips      = 6.0;      // 固定SL
input double   TP_FixedPips      = 9.0;      // 固定TP
input int      ATRPeriod         = 14;
input double   SL_ATR_Mult       = 1.0;      // ATR基準
input double   TP_ATR_Mult       = 1.5;

input bool     UseTrailing       = true;
input double   TrailStartPips    = 5.0;
input double   TrailStepPips     = 1.0;

input double   MaxSpreadPips     = 2.0;      // USDJPY: 約0.2銭（1pip=0.01円）
input int      SlippagePoints    = 3;
input int      CooldownMinutes   = 5;
input int      MaxTradesPerDay   = 20;
input int      MaxConsecLoss     = 3;

input bool     UseTokyo          = false;
input bool     UseEurope         = false;
input bool     UseNY             = false;
input bool     UseManualSessionFilter = false;  // 手動指定レンジを使用する場合はtrue
input string   ManualSessionRanges   = "";     // 例 "09:00-11:30;14:00-16:00"（UseManualSessionFilter=true時）

input bool     DebugMode         = true;
input double   MinATR_Pips       = 0.0;      // 0で無効。低ボラ回避時に設定

input int      MagicNumber       = 20251101;

// ----- 内部状態管理 -----
datetime lastEntryTime = 0;
string   gvLastEntryKey;

//+------------------------------------------------------------------+
// ユーティリティ（pips/points 換算：JPY桁に対応）
// pip定義：JPYペアは 0.01 を 1pip とみなす
double PipToPoints(double pips){
   // 例) USDJPY Digits=3(小数第3位=0.001がpoint) → 1pip(=0.01)は 10ポイント
   //     USDJPY Digits=2 → 1pip(=0.01)は 1ポイント
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
   if(sep<=0) return false;
   string hStr = StringSubstr(text, 0, sep);
   string mStr = StringSubstr(text, sep+1);
   int h = (int)StrToInteger(hStr);
   int m = (int)StrToInteger(mStr);
   if(h<0 || h>23 || m<0 || m>59) return false;
   minutes = h*60 + m;
   return true;
}

bool IsWithinManualSessions(){
   if(!UseManualSessionFilter) return true;
   string ranges = ManualSessionRanges;
   if(StringLen(ranges)==0) return true;

   datetime now = TimeCurrent();
   int curMinutes = TimeHour(now)*60 + TimeMinute(now);

   string entries[];
   ushort delim = ';';
   int count = StringSplit(ranges, delim, entries);
   if(count<=0){
      return true;
   }

   for(int i=0; i<count; i++){
      string token = TrimString(entries[i]);
      if(StringLen(token)==0) continue;
      int dash = StringFind(token, "-");
      if(dash<=0) continue;
      string startStr = StringSubstr(token, 0, dash);
      string endStr   = StringSubstr(token, dash+1);
      int startMin=0, endMin=0;
      if(!ParseTimeToMinutes(startStr, startMin) || !ParseTimeToMinutes(endStr, endMin)) continue;
      if(endMin < startMin){
         if(curMinutes>=startMin || curMinutes<=endMin) return true;
      }else{
         if(curMinutes>=startMin && curMinutes<=endMin) return true;
      }
   }
   return false;
}

bool IsTradingSession(){
   if(!IsWithinManualSessions()){
      if(DebugMode) Print("DBG: manual session filter off");
      return false;
   }
   if(!UseTokyo && !UseEurope && !UseNY) return true; // 全OFFなら無制限
   // ブローカー時刻（サーバー時刻）基準のざっくりセッション
   // 実ブローカーTZ差は運用時に調整してください
   int hour = TimeHour(TimeCurrent());
   bool tokyo  = (hour>=1  && hour<10);  // 01:00-09:59
   bool europe = (hour>=9  && hour<18);  // 09:00-17:59
   bool ny     = (hour>=14 && hour<=23); // 14:00-23:59
   bool allowed = (UseTokyo && tokyo) || (UseEurope && europe) || (UseNY && ny);
   if(!allowed && DebugMode) Print("DBG: session off");
   return allowed;
}

bool CooldownPassed(int &remainSeconds){
   datetime t = lastEntryTime;
   if(t==0){
      if(gvLastEntryKey=="") gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
      if(GlobalVariableCheck(gvLastEntryKey)){
         t = (datetime)GlobalVariableGet(gvLastEntryKey);
         lastEntryTime = t;
      }
   }
   if(t==0){
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
   int remain=0;
   return CooldownPassed(remain);
}

int TradesTodayCount(){
   int count=0;
   datetime dayStart = iTime(Symbol(), PERIOD_D1, 0);
   for(int i=OrdersHistoryTotal()-1; i>=0; i--){
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)){
         if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
         if(OrderOpenTime() >= dayStart) count++;
      }
   }
   // 未決済含めたい場合は現在のオーダーも追加
   for(int j=0; j<OrdersTotal(); j++){
      if(OrderSelect(j, SELECT_BY_POS, MODE_TRADES)){
         if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
         if(OrderOpenTime() >= dayStart) count++;
      }
   }
   return count;
}

int ConsecutiveLosses(){
   int consec=0;
   for(int i=OrdersHistoryTotal()-1; i>=0; i--){
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)==false) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      if(OrderType()>OP_SELL) continue; // 0/1以外は除外
      double profit = OrderProfit()+OrderSwap()+OrderCommission();
      if(profit<0){
         consec++;
      }else if(profit>0){
         break; // 直近勝ちで打ち切り
      }
   }
   return consec;
}

bool HasOpenPosition(){
   for(int i=0; i<OrdersTotal(); i++){
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)){
         if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber && (OrderType()==OP_BUY || OrderType()==OP_SELL))
            return true;
      }
   }
   return false;
}

double PipValuePerLot(){
   // 1 pip の金額（1ロットあたり）
   return MarketInfo(Symbol(), MODE_TICKVALUE) * PipToPoints(1.0);
}

double CalcLotsByRisk(double stopPips){
   if(stopPips<=0) return FixedLots;
   double riskMoney = AccountBalance() * (RiskPercentPerTrade/100.0);
   double pipValue1Lot = PipValuePerLot();
   if(pipValue1Lot<=0) return FixedLots;
   double lots = riskMoney / (stopPips * pipValue1Lot);
   // ブローカー制約に合わせて正規化
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   lots = MathMax(minLot, MathMin(maxLot, MathFloor(lots/step)*step));
   return NormalizeDouble(lots, 2);
}

void AdjustSLTPForBroker(double &slPoints, double &tpPoints){
   // StopLevel/FreezeLevel を考慮して最小距離を確保
   double stopLevelPts   = MarketInfo(Symbol(), MODE_STOPLEVEL);
   double freezeLevelPts = MarketInfo(Symbol(), MODE_FREEZELEVEL);
   double minDist = MathMax(stopLevelPts, freezeLevelPts);
   if(slPoints>0 && slPoints<minDist) slPoints = minDist;
   if(tpPoints>0 && tpPoints<minDist) tpPoints = minDist;
}

// クロス検出（直近バーでゴールデン/デッド）
bool CrossUp(double fastPrev, double slowPrev, double fastNow, double slowNow){
   return (fastPrev<=slowPrev && fastNow>slowNow);
}
bool CrossDown(double fastPrev, double slowPrev, double fastNow, double slowNow){
   return (fastPrev>=slowPrev && fastNow<slowNow);
}

void UpdateTrailingStops(){
   if(!UseTrailing) return;
   for(int i=0; i<OrdersTotal(); i++){
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)==false) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      int type = OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;

      double price = (type==OP_BUY)? Bid : Ask;
      double open  = OrderOpenPrice();
      double profitPips = PointsToPips( MathAbs(price - open)/Point );

      if(profitPips >= TrailStartPips){
         double newSL=OrderStopLoss();
         double trailPts = PipToPoints(TrailStepPips);
         if(type==OP_BUY){
            double candidateSL = price - trailPts*Point;
            if(candidateSL > newSL && candidateSL < price){
               // broker最小距離考慮
               double slp = MathAbs(price - candidateSL)/Point;
               double tpp = 0;
               AdjustSLTPForBroker(slp, tpp);
               candidateSL = price - slp*Point;
               if(!OrderModify(OrderTicket(), OrderOpenPrice(), candidateSL, OrderTakeProfit(), 0, clrAqua)){
                  Print("OrderModify trailing BUY failed. Err=", GetLastError());
               }
            }
         }else{ // OP_SELL
            double candidateSL = price + trailPts*Point;
            if((newSL==0 || candidateSL < newSL) && candidateSL > price){
               double slp = MathAbs(candidateSL - price)/Point;
               double tpp = 0;
               AdjustSLTPForBroker(slp, tpp);
               candidateSL = price + slp*Point;
               if(!OrderModify(OrderTicket(), OrderOpenPrice(), candidateSL, OrderTakeProfit(), 0, clrAqua)){
                  Print("OrderModify trailing SELL failed. Err=", GetLastError());
               }
            }
         }
      }
   }
}

bool PlaceOrder(int direction, double slPips, double tpPips){
   double price = (direction==OP_BUY)? Ask : Bid;
   double slPts = PipToPoints(slPips);
   double tpPts = PipToPoints(tpPips);
   AdjustSLTPForBroker(slPts, tpPts);

   double sl = 0, tp = 0;
   if(direction==OP_BUY){
      if(slPts>0) sl = price - slPts*Point;
      if(tpPts>0) tp = price + tpPts*Point;
   }else{
      if(slPts>0) sl = price + slPts*Point;
      if(tpPts>0) tp = price - tpPts*Point;
   }

   price = NormalizeDouble(price, Digits);
   if(sl>0) sl = NormalizeDouble(sl, Digits);
   if(tp>0) tp = NormalizeDouble(tp, Digits);

   double lots = (LotMode==FixedLot)? FixedLots : CalcLotsByRisk(slPips);
   int ticket = OrderSend(Symbol(), direction, lots, price, SlippagePoints, sl, tp, "MA-RSI", MagicNumber, 0, clrDodgerBlue);
   if(ticket<0){
      Print("OrderSend failed. Err=", GetLastError());
      return false;
   }
   // 成功 → クールダウン記録
   lastEntryTime = TimeCurrent();
   if(gvLastEntryKey=="") gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
   GlobalVariableSet(gvLastEntryKey, (double)lastEntryTime);
   return true;
}

void TryEntry(){
   if(HasOpenPosition()){
      if(DebugMode) Print("DBG: existing position open");
      return;
   }
   if(!IsTradingSession()) return;

   int cooldownRemain=0;
   if(!CooldownPassed(cooldownRemain)){
      if(DebugMode) Print("DBG: cooldown (remain=", cooldownRemain, "s)");
      return;
   }

   int tradesToday = TradesTodayCount();
   if(tradesToday >= MaxTradesPerDay){
      if(DebugMode) Print("DBG: day-cap reached (", tradesToday, "/", MaxTradesPerDay, ")");
      return;
   }

   int consecLoss = ConsecutiveLosses();
   if(consecLoss >= MaxConsecLoss){
      if(DebugMode) Print("DBG: consec-loss cap reached (", consecLoss, "/", MaxConsecLoss, ")");
      return;
   }

   double spread = GetSpreadPips();
   if(spread > MaxSpreadPips){
      if(DebugMode)
         Print("DBG: blocked by spread=", DoubleToString(spread,1), "p > max=", DoubleToString(MaxSpreadPips,1), "p");
      return;
   }

   int tf = InpTimeframe;
   int shiftNow = 1;  // 確定足
   int shiftPrev = 2;

   double fastNow  = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double slowNow  = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double fastPrev = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);
   double slowPrev = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);

   double rsiNow   = iRSI(Symbol(), tf, RSIPeriod, PRICE_CLOSE, shiftNow);

   bool needATR = (MinATR_Pips > 0.0) || (SLTP_CalcMode==UseATR);
   double atrPoints = 0.0;
   double atrPips = 0.0;
   if(needATR){
      atrPoints = iATR(Symbol(), tf, ATRPeriod, shiftNow) / Point;
      atrPips = PointsToPips(atrPoints);
   }

   if(MinATR_Pips > 0.0 && atrPips < MinATR_Pips){
      if(DebugMode)
         Print("DBG: blocked by low ATR=", DoubleToString(atrPips,1), "p < min=", DoubleToString(MinATR_Pips,1), "p");
      return;
   }

   double SLp=SL_FixedPips, TPp=TP_FixedPips;
   if(SLTP_CalcMode==UseATR){
      SLp = atrPips * SL_ATR_Mult;
      TPp = atrPips * TP_ATR_Mult;
   }

   bool longCond  = (Close[shiftNow] > slowNow) && CrossUp(fastPrev, slowPrev, fastNow, slowNow) && (rsiNow > RSIThreshMid);
   bool shortCond = (Close[shiftNow] < slowNow) && CrossDown(fastPrev, slowPrev, fastNow, slowNow) && (rsiNow < RSIThreshMid);

   if(longCond){
      if(PlaceOrder(OP_BUY, SLp, TPp))
         Print("BUY placed. SL=", DoubleToString(SLp,1), " TP=", DoubleToString(TPp,1));
   }else if(shortCond){
      if(PlaceOrder(OP_SELL, SLp, TPp))
         Print("SELL placed. SL=", DoubleToString(SLp,1), " TP=", DoubleToString(TPp,1));
   }
}

int OnInit(){
   gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
   return(INIT_SUCCEEDED);
}

int OnDeinit(){
   // 何もしない（必要ならGlobalVariableDel）
   return(0);
}

void OnTick(){
   // トレーリング
   UpdateTrailingStops();
   // エントリー判定
   TryEntry();
}
