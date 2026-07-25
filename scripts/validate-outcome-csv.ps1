[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AiDataPath,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [string]$ExpectedEaVersion = 'phase2_outcome_v1',

    [string]$ExpectedOutcomeTrackerVersion = 'tick_bidask_m5_h48_v1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Import-RequiredCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $path = Join-Path $BasePath ("{0}_{1}.csv" -f $Prefix, $Id)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required CSV was not found: $path"
    }

    return @(Import-Csv -LiteralPath $path)
}

function Get-DuplicateGroups {
    param([Parameter(Mandatory = $true)][object[]]$Values)

    return @($Values | Group-Object | Where-Object Count -gt 1)
}

function Get-RunIdMismatches {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    return @($Rows | Where-Object { $_.run_id -ne $RunId })
}

$manifest = Import-RequiredCsv -Prefix 'run_manifest' -BasePath $AiDataPath -Id $RunId
$candidates = Import-RequiredCsv -Prefix 'signal_candidates' -BasePath $AiDataPath -Id $RunId
$decisions = Import-RequiredCsv -Prefix 'signal_decisions' -BasePath $AiDataPath -Id $RunId
$outcomes = Import-RequiredCsv -Prefix 'signal_outcomes' -BasePath $AiDataPath -Id $RunId
$trades = Import-RequiredCsv -Prefix 'trade_results' -BasePath $AiDataPath -Id $RunId
$errors = Import-RequiredCsv -Prefix 'runtime_errors' -BasePath $AiDataPath -Id $RunId

$manifestCountInvalid = $manifest.Count -ne 1
$manifestEaVersionInvalid = $manifest.Count -eq 1 -and $manifest[0].ea_version -ne $ExpectedEaVersion

$candidateIds = @($candidates | ForEach-Object signal_id)
$decisionIds = @($decisions | ForEach-Object signal_id)
$outcomeIds = @($outcomes | ForEach-Object signal_id)
$tradeSignalIds = @($trades | ForEach-Object signal_id)
$tradeTickets = @($trades | ForEach-Object ticket)

$duplicateCandidates = Get-DuplicateGroups -Values $candidateIds
$duplicateDecisions = Get-DuplicateGroups -Values $decisionIds
$duplicateOutcomes = Get-DuplicateGroups -Values $outcomeIds
$duplicateTradeSignals = Get-DuplicateGroups -Values $tradeSignalIds
$duplicateTradeTickets = Get-DuplicateGroups -Values $tradeTickets

$candidateSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$candidateIds)
$decisionSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$decisionIds)
$outcomeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$outcomeIds)
$tradeSignalSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$tradeSignalIds)

$missingDecisions = @($candidateIds | Where-Object { -not $decisionSet.Contains($_) })
$missingOutcomes = @($candidateIds | Where-Object { -not $outcomeSet.Contains($_) })
$orphanDecisions = @($decisionIds | Where-Object { -not $candidateSet.Contains($_) })
$orphanOutcomes = @($outcomeIds | Where-Object { -not $candidateSet.Contains($_) })
$orphanTrades = @($tradeSignalIds | Where-Object { -not $candidateSet.Contains($_) })

$tradeDecisionIds = @($decisions |
    Where-Object final_decision -eq 'TRADE' |
    ForEach-Object signal_id)
$tradeDecisionSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$tradeDecisionIds)
$missingTradeResults = @($tradeDecisionIds | Where-Object { -not $tradeSignalSet.Contains($_) })
$tradesWithoutTradeDecision = @($tradeSignalIds | Where-Object { -not $tradeDecisionSet.Contains($_) })

$invalidOutcomeCodes = @($outcomes | Where-Object {
    $_.outcome -notin @('TP_FIRST', 'SL_FIRST', 'EXPIRED', 'AMBIGUOUS', 'TRUNCATED')
})
$invalidLabels = @($outcomes | Where-Object {
    ($_.outcome -eq 'TP_FIRST' -and $_.label_tp_before_sl -ne '1') -or
    ($_.outcome -eq 'SL_FIRST' -and $_.label_tp_before_sl -ne '0') -or
    ($_.outcome -in @('EXPIRED', 'AMBIGUOUS', 'TRUNCATED') -and $_.label_tp_before_sl -ne '')
})
$invalidTrackerVersions = @($outcomes | Where-Object {
    $_.outcome_tracker_version -ne $ExpectedOutcomeTrackerVersion
})
$negativeExcursions = @($outcomes | Where-Object {
    ([double]$_.mfe_pips -lt 0) -or ([double]$_.mae_pips -lt 0)
})
$invalidExpiredBars = @($outcomes | Where-Object {
    $_.outcome -eq 'EXPIRED' -and [int]$_.bars_to_outcome -lt 48
})

$runIdMismatches = @(
    @(Get-RunIdMismatches -Rows $manifest)
    @(Get-RunIdMismatches -Rows $candidates)
    @(Get-RunIdMismatches -Rows $decisions)
    @(Get-RunIdMismatches -Rows $outcomes)
    @(Get-RunIdMismatches -Rows $trades)
    @(Get-RunIdMismatches -Rows $errors)
)

$summary = [ordered]@{
    RunId = $RunId
    ManifestRows = $manifest.Count
    ManifestEaVersion = if ($manifest.Count -eq 1) { $manifest[0].ea_version } else { '' }
    ExpectedEaVersion = $ExpectedEaVersion
    Candidates = $candidates.Count
    Decisions = $decisions.Count
    Outcomes = $outcomes.Count
    TradeDecisions = $tradeDecisionIds.Count
    TradeResults = $trades.Count
    RuntimeErrors = $errors.Count
    RunIdMismatches = $runIdMismatches.Count
    DuplicateCandidates = $duplicateCandidates.Count
    DuplicateDecisions = $duplicateDecisions.Count
    DuplicateOutcomes = $duplicateOutcomes.Count
    DuplicateTradeSignals = $duplicateTradeSignals.Count
    DuplicateTradeTickets = $duplicateTradeTickets.Count
    MissingDecisions = $missingDecisions.Count
    MissingOutcomes = $missingOutcomes.Count
    OrphanDecisions = $orphanDecisions.Count
    OrphanOutcomes = $orphanOutcomes.Count
    OrphanTrades = $orphanTrades.Count
    MissingTradeResults = $missingTradeResults.Count
    TradesWithoutTradeDecision = $tradesWithoutTradeDecision.Count
    InvalidOutcomeCodes = $invalidOutcomeCodes.Count
    InvalidLabels = $invalidLabels.Count
    InvalidTrackerVersions = $invalidTrackerVersions.Count
    InvalidExpiredBars = $invalidExpiredBars.Count
    NegativeExcursions = $negativeExcursions.Count
}

[pscustomobject]$summary | Format-List

$outcomes |
    Group-Object outcome |
    Sort-Object Name |
    Select-Object Name, Count |
    Format-Table -AutoSize

$failed = @(
    [int]$manifestCountInvalid,
    [int]$manifestEaVersionInvalid,
    $runIdMismatches.Count,
    $duplicateCandidates.Count,
    $duplicateDecisions.Count,
    $duplicateOutcomes.Count,
    $duplicateTradeSignals.Count,
    $duplicateTradeTickets.Count,
    $missingDecisions.Count,
    $missingOutcomes.Count,
    $orphanDecisions.Count,
    $orphanOutcomes.Count,
    $orphanTrades.Count,
    $missingTradeResults.Count,
    $tradesWithoutTradeDecision.Count,
    $invalidOutcomeCodes.Count,
    $invalidLabels.Count,
    $invalidTrackerVersions.Count,
    $invalidExpiredBars.Count,
    $negativeExcursions.Count,
    $errors.Count
) | Where-Object { $_ -gt 0 }

if ($failed.Count -gt 0) {
    throw 'Outcome CSV validation failed. Review the counts above.'
}

Write-Host 'Outcome CSV validation passed.' -ForegroundColor Green
