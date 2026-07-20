//+------------------------------------------------------------------+
//|  USDJPY_Scalp_MA_RSI.mq4                                         |
//|  Logic A: 5EMA/20EMA + RSI filter (Rakuten MT4 tuned)            |
//+------------------------------------------------------------------+
#property strict

input int    InpTimeframe        = PERIOD_M5;
input int    FastEMA             = 5;
input int    SlowEMA             = 20;
input int    RSIPeriod           = 14;
// input double RSIThreshMid        = 50.0; // ←これは削除かコメントアウト
input int    RSI_Level_Buy       = 55;
input int    RSI_Level_Sell      = 45;

enum RiskMode { FixedLot=0, RiskPercent=1 };
input RiskMode LotMode           = RiskPercent;
input double   FixedLots         = 0.10;
input double   RiskPercentPerTrade = 1.0; 
enum SLTPMode { UseFixed=0, UseATR=1 };
input SLTPMode SLTP_CalcMode     = UseFixed;
input double   SL_FixedPips      = 6.0; 
input double   TP_FixedPips      = 9.0;
input int      ATRPeriod         = 14;
input double   SL_ATR_Mult       = 1.0;
input double   TP_ATR_Mult       = 1.5;

input bool     UseTrailing       = true;
input double   TrailStartPips    = 5.0;
input double   TrailStepPips     = 1.0;

// --- 既存のinputの下に追加 ---
input bool   UseBreakEven      = true;
input double BE_Trigger_Mult   = 0.5;
input double BE_Offset_Pips    = 0.5;

input double   MaxSpreadPips     = 1.5;
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

input int    ADXPeriod         = 14;
input int    ADXThreshold      = 20;

input bool   UseMTF_Filter     = true;
input int    MTF_Timeframe     = 60;
input int    MTF_MA_Period     = 20;

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
   // Tokyo: 日本時間9:00はサーバー時間(冬+7/夏+6)で 冬2:00/夏3:00
   // ここでは冬時間基準で 02:00 から許可するように変更
   bool tokyo  = (hour>=2  && hour<10);  // 02:00-09:59 (JST 09:00-16:59 Winter)
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
   datetime t = lastEntryTime;
   if(t==0){
      // グローバル変数から復元
      if(gvLastEntryKey=="") gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);
      if(GlobalVariableCheck(gvLastEntryKey)) t = (datetime)GlobalVariableGet(gvLastEntryKey);
   }
   if(t==0) return true;

   // 【追加】もし記録されている時間が「現在より未来（バックテスト再開時など）」なら無視する
   if(t > TimeCurrent()){
       return true;
   }

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
   datetime dayStart = iTime(Symbol(), PERIOD_D1, 0); // 今日の開始時間

   for(int i=OrdersHistoryTotal()-1; i>=0; i--){
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)==false) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      if(OrderType()>OP_SELL) continue;
      
      // 【追加】もし履歴の日付が「今日より前」なら、そこでカウント終了（昨日の負けはノーカウント）
      if(OrderCloseTime() < dayStart) break;

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

void UpdateBreakEven(){
   if(!UseBreakEven) return;

   for(int i=0; i<OrdersTotal(); i++){
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)==false) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;
      
      int type = OrderType();
      double openPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double takeProfit = OrderTakeProfit();

      // TPが設定されていない場合はスキップ
      if(takeProfit == 0) continue;

      if(type == OP_BUY){
         double targetDist = takeProfit - openPrice;
         double currentDist = Bid - openPrice;
         
         // TPまでの距離の x% (例:50%) まで進んだら
         if(currentDist >= targetDist * BE_Trigger_Mult){
            // 新しいSL位置（建値 + オフセット）
            double newSL = openPrice + PipToPoints(BE_Offset_Pips) * Point;
            
            // まだSLが建値より下にある場合のみ移動
            if(newSL > currentSL && newSL < Bid){
                if(!OrderModify(OrderTicket(), openPrice, newSL, takeProfit, 0, clrGreen)){
                   Print("BreakEven modify failed. Err=", GetLastError());
                }
            }
         }
      }
      else if(type == OP_SELL){
         double targetDist = openPrice - takeProfit;
         double currentDist = openPrice - Ask;
         
         if(currentDist >= targetDist * BE_Trigger_Mult){
            double newSL = openPrice - PipToPoints(BE_Offset_Pips) * Point;
            
            // まだSLが建値より上にある場合のみ移動
            if( (currentSL == 0 || newSL < currentSL) && newSL > Ask){
                if(!OrderModify(OrderTicket(), openPrice, newSL, takeProfit, 0, clrGreen)){
                   Print("BreakEven modify failed. Err=", GetLastError());
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
   if(HasOpenPosition()) return;
   if(!IsTradingSession()) return;
   if(!CooldownPassed()){ Print("Cooldown not passed"); return; }

   // リスク制御
   if(TradesTodayCount() >= MaxTradesPerDay){ 
       // ログ省略（必要ならstatic変数で制御）
       return; 
   }

   int consec = ConsecutiveLosses();
   if(consec >= MaxConsecLoss){ 
       // 【修正】足が変わったタイミングでのみ1回だけログを出す
       static datetime lastLogBar = 0;
       if(lastLogBar != Time[0]){
           Print("Consecutive loss cap reached (Today: ", consec, ")");
           lastLogBar = Time[0];
       }
       return; 
   }

   // スプレッドチェック
   double spread = GetSpreadPips();
   if(spread > MaxSpreadPips){ Print("Spread too wide: ", DoubleToString(spread,1), " pips"); return; }

   // インジ計算
   int tf = InpTimeframe;
   
   // 【変更】0(現在足)ではなく、1(確定足)と2(その前)を見ることでダマシを防ぐ
   int shiftNow=1, shiftPrev=2; 

   double fastNow  = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double slowNow  = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftNow);
   double fastPrev = iMA(Symbol(), tf, FastEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);
   double slowPrev = iMA(Symbol(), tf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, shiftPrev);
   double rsiNow   = iRSI(Symbol(), tf, RSIPeriod, PRICE_CLOSE, shiftNow);
   
   // 【追加】ADXによるトレンド強度フィルタ
   double adx = iADX(Symbol(), tf, ADXPeriod, PRICE_CLOSE, MODE_MAIN, shiftNow);
   if(adx < ADXThreshold) return; // トレンドが弱い場合は見送り

   // ATR-based SL/TP
   double SLp=SL_FixedPips, TPp=TP_FixedPips;
   if(SLTP_CalcMode==UseATR){
      double atr = iATR(Symbol(), tf, ATRPeriod, shiftNow) / Point; 
      double atrPips = PointsToPips(atr);
      SLp = atrPips * SL_ATR_Mult;
      TPp = atrPips * TP_ATR_Mult;
   }

   // 条件判定（RSI判定を新しい変数に差し替え）
   bool longCond  = (Close[shiftNow] > slowNow) && CrossUp(fastPrev, slowPrev, fastNow, slowNow) && (rsiNow > RSI_Level_Buy);
   bool shortCond = (Close[shiftNow] < slowNow) && CrossDown(fastPrev, slowPrev, fastNow, slowNow) && (rsiNow < RSI_Level_Sell);

   // ============================================================
   // 【追加】上位足(MTF)トレンドフィルター
   // ============================================================
   if(UseMTF_Filter){
       // 上位足のMA（現在の足と1つ前の足）を取得
       double mtfMaNow  = iMA(Symbol(), MTF_Timeframe, MTF_MA_Period, 0, MODE_EMA, PRICE_CLOSE, 1);
       double mtfMaPrev = iMA(Symbol(), MTF_Timeframe, MTF_MA_Period, 0, MODE_EMA, PRICE_CLOSE, 2);

       // 上位足MAが上向きか下向きか判定
       bool isUptrend   = (mtfMaNow > mtfMaPrev);
       bool isDowntrend = (mtfMaNow < mtfMaPrev);
       
       // フィルタ適用（価格がMAより上/下にあるかも条件に加えるとより強力ですが、まずは傾きだけで判定）
       // 上位足が上向きでなければ、ロングを禁止（ショート専用にするわけではないがロング条件を潰す）
       if(!isUptrend)   longCond = false; 
       
       // 上位足が下向きでなければ、ショートを禁止
       if(!isDowntrend) shortCond = false;
   }
   // ============================================================

   if(longCond){
      if(PlaceOrder(OP_BUY, SLp, TPp))
         Print("BUY placed. SL=", DoubleToString(SLp,1), " TP=", DoubleToString(TPp,1), " ADX=", DoubleToString(adx,1));
   }else if(shortCond){
      if(PlaceOrder(OP_SELL, SLp, TPp))
         Print("SELL placed. SL=", DoubleToString(SLp,1), " TP=", DoubleToString(TPp,1), " ADX=", DoubleToString(adx,1));
   }
}

int OnInit(){
   gvLastEntryKey = StringFormat("GV_LASTENTRY_%s_%d", Symbol(), MagicNumber);

   // 【追加】バックテスト時は、過去の残留データを削除してクリーンな状態で始める
   if(IsTesting()){
      if(GlobalVariableCheck(gvLastEntryKey)) GlobalVariableDel(gvLastEntryKey);
   }

   return(INIT_SUCCEEDED);
}

int OnDeinit(){
   // 何もしない（必要ならGlobalVariableDel）
   return(0);
}

void OnTick(){
   // トレーリング（以前からあるもの）
   UpdateTrailingStops();
   
   // 【追加】ブレイクイーブン監視
   UpdateBreakEven();

   // エントリー判定
   TryEntry();
}
