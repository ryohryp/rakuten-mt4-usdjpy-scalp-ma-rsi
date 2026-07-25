# USDJPY Scalping EA (Pullback×RSI) for Rakuten MT4

**Rakuten MetaTrader 4** を想定した USDJPY 向けスキャルピングEAです。
H1のトレンド方向に対するM5の押し目・戻りから、RSIとADXの再加速を確認してエントリーします。

> 現在は研究・データ収集段階です。既存バックテストでは正の期待値を確認できていないため、リアル口座投入を前提としません。

## インストール

Phase 1以降のEAは複数ファイル構成です。`USDJPY_Scalp_MA_RSI.mq4`だけをコピーすると、`AIData/*.mqh`を開けず、その後に型・関数未定義の大量エラーが連鎖します。

### PowerShellによる一括配置

リポジトリのルートで次を実行します。`TerminalDataPath`には、Rakuten MT4の「ファイル → データフォルダを開く」で表示されるフォルダを指定します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install-rakuten-mt4.ps1 `
  -TerminalDataPath "$env:APPDATA\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F"
```

スクリプトは次を配置し、7ファイルが存在することを検証します。

```text
<MQL4>/Experts/USDJPY_Scalp_MA_RSI.mq4
<MQL4>/Include/AIData/Types.mqh
<MQL4>/Include/AIData/RunContext.mqh
<MQL4>/Include/AIData/CsvWriter.mqh
<MQL4>/Include/AIData/OutcomeTracker.mqh
<MQL4>/Include/AIData/SignalLogger.mqh
<MQL4>/Include/AIData/TradeResultLogger.mqh
<MQL4>/Presets/usdjpy_m5_default.set
```

配置後は、**同じRakuten MT4端末からMetaEditorを開き直し**、`USDJPY_Scalp_MA_RSI.mq4`をコンパイルします。

### 手動配置

スクリプトを使わない場合は、次のディレクトリ構造を保ったままコピーします。

```text
src/MQL4/Experts/USDJPY_Scalp_MA_RSI.mq4
  → <terminal>/MQL4/Experts/USDJPY_Scalp_MA_RSI.mq4

src/MQL4/Include/AIData/*.mqh
  → <terminal>/MQL4/Include/AIData/*.mqh
```

最初のエラーが`can't open ... Include\AIData\*.mqh`で、その後に多数の`declaration without type`や`function not defined`が出る場合、後続エラーはinclude不足によるカスケードです。まずすべての`.mqh`の配置を直します。

## エントリー基準

買いは次の条件をすべて満たした確定足で判定し、売りは反対条件です。

- H1 EMA20が上向きで、H1終値がEMA20より上
- M5 EMA5がEMA20より上
- 過去3本以内のM5足がEMA5まで押し戻され、EMA20を大きく崩していない
- 最新確定足がEMA5を回復し、前足終値より上で確定
- RSI(14)が52以上かつ前足より上昇
- ADXが20以上

ADXの前足比上昇は任意設定です。初期版では、押し目・RSI50クロス・前足高値更新・ADX上昇を同じ足に要求したため、1年間で5件まで取引が減りました。現在のベースラインでは、押し目を複数足のセットアップとして扱い、再加速足と分離しています。

旧ロジックのEMAクロス追随は廃止し、クロス後の高値づかみ・安値売りを避けます。

## 現在の安全基準

- 確定足で1回だけエントリー判定
- 1ポジション限定、クールダウン、1日回数上限、連続損失上限
- 日次実現損失率による停止
- 固定スプレッド上限と `Spread / ATR` 上限の二重チェック
- 低ATR相場を除外
- ブローカー調整後の実SL距離でリスクロットを計算
- 初期リスクを注文コメントに保存し、建値・トレーリングをR倍で管理

## AI学習データログ（Phase 1・2）

`EnableDatasetLogging=true` の場合、raw setup成立後、安全フィルターより前に候補を保存します。発注された候補だけでなく、セッション外、既存ポジション、スプレッド、日次制限などで見送った候補も記録します。

Phase 2では、保存できた全候補を仮想ポジションとして追跡します。実際に発注したかどうかには依存せず、候補時点の仮想Entry・SL・TPを固定して結果を付けます。

出力先はMT4のファイル領域にある `AIData/` です。Strategy Testerでは `Tester/Files/AIData/` に分離されます。

```text
AIData/
  run_manifest_<run_id>.csv
  signal_candidates_<run_id>.csv
  signal_decisions_<run_id>.csv
  signal_outcomes_<run_id>.csv
  trade_results_<run_id>.csv
  runtime_errors_<run_id>.csv
```

記録する内容:

- 実行条件とバージョン情報
- 候補時点の価格、ATR、RSI、ADX、H1方向、ローソク足形状
- deterministic guardの最初の見送り理由
- `signal_id ↔ signal_key ↔ ticket` の関連
- 全候補の仮想TP/SL先着、MFE/MAE、経過バー数
- 実取引の損益、R損益、保有時間、MFE/MAE

### 仮想Outcome判定

- 追跡期間: M5の48バー
- BUYのTP/SL判定: Bidを使用
- SELLのTP/SL判定: Askを使用
- `TP_FIRST`: SLより先にTPへ到達。学習ラベル1
- `SL_FIRST`: TPより先にSLへ到達。学習ラベル0
- `EXPIRED`: 48バー以内にどちらにも到達しない
- `AMBIGUOUS`: 同一評価点でTP/SL双方が成立し、先着を確定できない
- `TRUNCATED`: テスト終了やEA停止により追跡期間を完走できない

`EXPIRED`、`AMBIGUOUS`、`TRUNCATED`のラベルは空欄とし、初期学習では除外します。Outcomeの正確な先着順を得るため、Strategy Testerは**全ティック**モデルを使用します。

注文コメントには長い`signal_id`ではなく短い`signal_key`を保存します。AI推論はまだ実装しておらず、現在の判断モードは常に`OFF`です。

現行版は実行中の候補だけをメモリで追跡します。EA再起動を跨ぐpending候補の復元は未対応で、停止時に残った候補は`TRUNCATED`として扱います。詳細は [`docs/ai-learning-data-spec.md`](docs/ai-learning-data-spec.md) を参照してください。

## 推奨ベースライン

`presets/usdjpy_m5_default.set` は入口ロジックとログ出力を比較するため、次を既定値にしています。

- RSI中心水準: 50
- RSIモメンタム幅: 2（買い52以上、売り48以下）
- 押し目探索期間: 過去3本
- 押し目許容幅: 0.5pips
- ADX上昇必須: OFF
- H1価格方向一致必須
- 学習データログ: ON
- 特徴量schema: `1.0.0`
- Outcome: +1.5R / -1R先着、M5 48バー
- 1取引リスク: 0.25%
- SL/TP: ATRの1.0倍 / 1.5倍
- 建値移動: OFF
- トレーリング: OFF
- 最大スプレッド: 0.8pips
- Spread / ATR: 20%以下
- 最小ATR: 3.0pips
- 最大8取引/日
- 日次損失上限: 0.5%
- NYセッションのみ（ブローカーサーバー時刻14:00-24:00）

セッション時刻はブローカーサーバー基準です。夏時間・冬時間の切替時には調整してください。

## 検証順序

1. MetaEditorでエラー0・警告0を確認
2. ログOFF版とログON版で注文結果が一致することを確認
3. candidateとdecisionが`signal_id`で1対1に結合できることを確認
4. outcomeがcandidateへ一意に結合できることを確認
5. TRADE候補がticketとtrade resultへ結合できることを確認
6. TP_FIRST / SL_FIRST / EXPIRED / TRUNCATEDの件数とMFE/MAEを確認
7. 不整合チャートエラー0の履歴で学習用CSVを再生成

リアル口座投入前に、変動スプレッドとスリッページを含むバックテストおよびフォワードテストを実施してください。
