# USDJPY Scalping EA (Pullback×RSI) for Rakuten MT4

**Rakuten MetaTrader 4** を想定した USDJPY 向けスキャルピングEAです。
H1のトレンド方向に対するM5の押し目・戻りから、RSIとADXの再加速を確認してエントリーします。

> 現在は研究・データ収集段階です。既存バックテストでは正の期待値を確認できていないため、リアル口座投入を前提としません。

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

## AI学習データログ（Phase 1）

`EnableDatasetLogging=true` の場合、raw setup成立後、安全フィルターより前に候補を保存します。発注された候補だけでなく、セッション外、既存ポジション、スプレッド、日次制限などで見送った候補も記録します。

出力先はMT4のファイル領域にある `AIData/` です。Strategy Testerでは `Tester/Files/AIData/` に分離されます。

```text
AIData/
  run_manifest_<run_id>.csv
  signal_candidates_<run_id>.csv
  signal_decisions_<run_id>.csv
  trade_results_<run_id>.csv
  runtime_errors_<run_id>.csv
```

Phase 1で記録する内容:

- 実行条件とバージョン情報
- 候補時点の価格、ATR、RSI、ADX、H1方向、ローソク足形状
- deterministic guardの最初の見送り理由
- `signal_id ↔ signal_key ↔ ticket` の関連
- 実取引の損益、R損益、保有時間、MFE/MAE

注文コメントには長い`signal_id`ではなく短い`signal_key`を保存します。AI推論と仮想TP/SL Outcome追跡はまだ実装しておらず、現在の判断モードは常に`OFF`です。

Phase 1の実取引追跡は、現在のEA起動中に発注した注文だけを対象とします。EA再起動前から残っている注文の復元と二重出力防止はPhase 2で実装します。詳細は [`docs/ai-learning-data-spec.md`](docs/ai-learning-data-spec.md) を参照してください。

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
4. TRADE候補がticketとtrade resultへ結合できることを確認
5. 次のPhase 2で全候補の仮想TP/SL Outcomeを追加

リアル口座投入前に、変動スプレッドとスリッページを含むバックテストおよびフォワードテストを実施してください。
