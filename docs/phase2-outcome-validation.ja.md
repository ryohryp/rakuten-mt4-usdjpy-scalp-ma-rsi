# Phase 2 Outcome検証要約

1. インストーラーでEAと`AIData` includeを再配置する。
2. MetaEditorでエラー0・警告0を確認する。
3. 同一条件でログOFF／ONを比較し、売買結果が完全一致することを確認する。
4. `signal_candidates`、`signal_decisions`、`signal_outcomes`が`signal_id`で1対1になることを確認する。
5. `scripts/validate-outcome-csv.ps1`で重複・欠損・ラベル・MFE/MAE・runtime errorを検査する。
6. 最終学習データは不整合チャートエラー0件で再生成する。
