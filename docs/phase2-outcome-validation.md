# Phase 2 Outcome validation

## 1. Install and compile

Close MetaEditor before installation. If Rakuten MT4 still locks a file, close the terminal as well.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install-rakuten-mt4.ps1 `
  -TerminalDataPath "$env:APPDATA\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F"
```

The installer calculates a fingerprint from the EA source and all `AIData/*.mqh` files. When that fingerprint changes, it deletes the existing `USDJPY_Scalp_MA_RSI.ex4` so Strategy Tester cannot silently execute a stale binary.

Compile `USDJPY_Scalp_MA_RSI.mq4` in the MetaEditor opened from the same Rakuten MT4 terminal.

Acceptance:

- 0 errors and 0 warnings
- `USDJPY_Scalp_MA_RSI.ex4` is recreated after installation
- the EX4 modified time matches the latest compile

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
& .\scripts\validate-outcome-csv.ps1 `
  -AiDataPath "$env:APPDATA\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F\tester\files\AIData" `
  -RunId "<run_id>"
```

Acceptance:

- manifest contains exactly one row
- manifest `ea_version` is `phase2_outcome_v1`
- all outcome rows use tracker version `tick_bidask_m5_h48_v1`
- candidate, decision and outcome counts match
- TRADE decisions and trade results match one-to-one
- duplicate IDs and tickets: 0
- missing/orphan rows: 0
- invalid outcome codes and labels: 0
- negative MFE/MAE: 0
- runtime errors: 0
- final output is `Outcome CSV validation passed.`

## 5. Validation evidence

The long compatibility run reproduced the Phase 1 trading result exactly:

- trades: 1,103
- net profit: -3,632.13
- profit factor: 0.76
- maximum drawdown: 36.72%

The uploaded Phase 2 outcome dataset contained:

- candidates: 16,025
- decisions: 16,025
- outcomes: 16,025
- trade results: 1,103
- runtime errors: 0

The short smoke-test period completed with 0 mismatched chart errors. Its first manifest exposed a stale EX4 because `ea_version` was still `phase1_logging_v1`; the installer now invalidates stale compiled binaries when source fingerprints change.

## 6. Data quality

The earlier long-history run produced 11 mismatched chart errors. It is sufficient for behavior compatibility, but the final learning dataset must be regenerated with 0 mismatched chart errors and a `phase2_outcome_v1` manifest.
