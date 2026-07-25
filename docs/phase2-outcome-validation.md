# Phase 2 Outcome validation

## 1. Install and compile

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install-rakuten-mt4.ps1 `
  -TerminalDataPath "$env:APPDATA\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F"
```

Compile `USDJPY_Scalp_MA_RSI.mq4` in the MetaEditor opened from the same Rakuten MT4 terminal.

Acceptance: 0 errors and 0 warnings.

## 2. Behavior compatibility

Run the same Strategy Tester period twice with every setting identical except:

1. `EnableDatasetLogging=false`
2. `EnableDatasetLogging=true`

Compare total trades, direction counts, net profit, gross profit, gross loss and drawdown.

Acceptance: exact match.

## 3. Outcome CSV

The logging-on run must create:

```text
Tester/Files/AIData/signal_outcomes_<run_id>.csv
```

Expected outcome codes:

- `TP_FIRST`: label `1`
- `SL_FIRST`: label `0`
- `EXPIRED`: empty label
- `AMBIGUOUS`: empty label
- `TRUNCATED`: empty label

Every candidate must have exactly one decision and one outcome after Strategy Tester shutdown.

## 4. Automated validation

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\validate-outcome-csv.ps1 `
  -AiDataPath "$env:APPDATA\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F\tester\files\AIData" `
  -RunId "<run_id>"
```

Acceptance:

- candidate, decision and outcome counts match
- duplicate IDs: 0
- missing/orphan rows: 0
- invalid labels: 0
- negative MFE/MAE: 0
- runtime errors: 0

## 5. Data quality

The current history produced 11 mismatched chart errors. Phase 2 functional validation may proceed, but the final learning dataset must be regenerated after history repair with 0 mismatched chart errors.
