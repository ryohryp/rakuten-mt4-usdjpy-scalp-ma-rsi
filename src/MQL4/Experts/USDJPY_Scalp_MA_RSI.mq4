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

input double   MaxSpreadPips     = 0.4;      // 0.4銭 = 0.04円 = 4pips?（※JPYのpip=0.01円）
input int      SlippagePoints    = 3;
input int      CooldownMinutes   = 5;
input int      MaxTradesPerDay   = 20;
input int      MaxConsecLoss     = 3;

input bool     UseTokyo          = true;
input bool     UseEurope         = true;
input bool     UseNY             = true;

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

bool IsTradingSession(){
   if(UseTokyo==false && UseEurope==false && UseNY==false) return true; // 全OFFなら制限なし
   // ブローカー時刻（サーバー時刻）基準のざっくりセッション
   // 実ブローカーTZ差は運用時に調整してください
   int hour = TimeHour(TimeCurrent());
   bool tokyo  = (hour>=1  && hour<10);  // 01:00-09:59
   bool europe = (hour>=9  && hour<18);  // 09:00-17:59
   bool ny     = (hour>=14 && hour<=23); // 14:00-23:59
   if( (UseTokyo && tokyo) || (UseEurope && europe) || (UseNY && ny) ) return true;
   return false;
}

bool CooldownPassed(){
   datetime t = lastEntryTime;
   if(t==0){
      // グローバル変数から復元（EA再起動対策）
      if(gvLastEntryKey=="") gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
      if(GlobalVariableCheck(gvLastEntryKey)) t = (datetime)GlobalVariableGet(gvLastEntryKey);
   }
   if(t==0) return true;
   return (TimeCurrent() - t) >= CooldownMinutes * 60;
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
   if(HasOpenPosition()) return;
   if(!IsTradingSession()) return;
   if(!CooldownPassed()){ Print("Cooldown not passed"); return; }

   // リスク制御
   if(TradesTodayCount() >= MaxTradesPerDay){ Print("Daily trade cap reached"); return; }
   if(ConsecutiveLosses() >= MaxConsecLoss){ Print("Consecutive loss cap reached"); return; }

   // スプレッド
   double spread = GetSpreadPips();
   if(spread > MaxSpreadPips){ Print("Spread too wide: ", DoubleToString(spread,1), " pips"); return; }

   // インジ計算
   int tf = InpTimeframe;
   // Close[0]は未確定、エントリー判定は確定足ベース
   int shiftNow=0, shiftPrev=1;

   double fastNow  = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double slowNow  = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double fastPrev = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);
   double slowPrev = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);

   double rsiNow   = iRSI(Symbol(), tf, RSIPeriod, PRICE_CLOSE, shiftNow);

   // ATR-based SL/TP（必要なら）
   double SLp=SL_FixedPips, TPp=TP_FixedPips;
   if(SLTP_CalcMode==UseATR){
      double atr = iATR(Symbol(), tf, ATRPeriod, shiftNow) / Point; // ATR（ポイント）
      double atrPips = PointsToPips(atr);
      SLp = atrPips * SL_ATR_Mult;
      TPp = atrPips * TP_ATR_Mult;
   }

   // 条件：ロング
   bool longCond  = (Close[shiftNow] > slowNow) && CrossUp(fastPrev, slowPrev, fastNow, slowNow) && (rsiNow > RSIThreshMid);
   // 条件：ショート
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
