MT4の `MQL4/Experts` に配置してビルド。

## 推奨デフォルト
- Timeframe：M5
- MA：5/20, RSI：14(閾値50)
- SL/TP：6pips / 9pips（RR=1:1.5）
- MaxSpread：0.4pips
- Cooldown：5分、1日最大20回、連続損失上限3

## 使い方（ストラテジーテスター）
1. 通貨：USDJPY、期間：検証したい範囲、モデル：全ティック
2. `presets/usdjpy_m5_default.set` を読み込み（任意）
3. レポート／ログで抑制条件（Spread/Cooldown）を確認
4. 良ければ ATR/Trailing を段階的に有効化

## 注意（楽天の取引規定）
- 「短時間の連続取引」規定に配慮するため、**クールダウン・回数制限**を実装済み。  
- 実運用前に必ず**デモ検証**し、パラメータをブローカー条件に合わせて調整してください。

## ライセンス
MIT（`LICENSE` 参照）

## 開発ルール（概要）
- ブランチ運用：`main` 安定版、`develop` 次版、`feature/*` 機能別
- 版管理：Semantic Versioning (例: v0.1.0)
- 変更履歴：`CHANGELOG.md`（Keep a Changelog形式）
