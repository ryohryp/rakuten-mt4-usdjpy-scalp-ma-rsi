[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AiDataPath,

    [Parameter(Mandatory = $true)]
    [string]$RunId
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

$candidates = Import-RequiredCsv -Prefix 'signal_candidates' -BasePath $AiDataPath -Id $RunId
$decisions = Import-RequiredCsv -Prefix 'signal_decisions' -BasePath $AiDataPath -Id $RunId
$outcomes = Import-RequiredCsv -Prefix 'signal_outcomes' -BasePath $AiDataPath -Id $RunId
$errors = Import-RequiredCsv -Prefix 'runtime_errors' -BasePath $AiDataPath -Id $RunId

$candidateIds = @($candidates | ForEach-Object signal_id)
$decisionIds = @($decisions | ForEach-Object signal_id)
$outcomeIds = @($outcomes | ForEach-Object signal_id)

$duplicateCandidates = @($candidateIds | Group-Object | Where-Object Count -gt 1)
$duplicateDecisions = @($decisionIds | Group-Object | Where-Object Count -gt 1)
$duplicateOutcomes = @($outcomeIds | Group-Object | Where-Object Count -gt 1)

$candidateSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$candidateIds)
$decisionSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$decisionIds)
$outcomeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$outcomeIds)

$missingDecisions = @($candidateIds | Where-Object { -not $decisionSet.Contains($_) })
$missingOutcomes = @($candidateIds | Where-Object { -not $outcomeSet.Contains($_) })
$orphanDecisions = @($decisionIds | Where-Object { -not $candidateSet.Contains($_) })
$orphanOutcomes = @($outcomeIds | Where-Object { -not $candidateSet.Contains($_) })

$invalidOutcomeCodes = @($outcomes | Where-Object {
    $_.outcome -notin @('TP_FIRST', 'SL_FIRST', 'EXPIRED', 'AMBIGUOUS', 'TRUNCATED')
})
$invalidLabels = @($outcomes | Where-Object {
    ($_.outcome -eq 'TP_FIRST' -and $_.label_tp_before_sl -ne '1') -or
    ($_.outcome -eq 'SL_FIRST' -and $_.label_tp_before_sl -ne '0') -or
    ($_.outcome -in @('EXPIRED', 'AMBIGUOUS', 'TRUNCATED') -and $_.label_tp_before_sl -ne '')
})
$negativeExcursions = @($outcomes | Where-Object {
    ([double]$_.mfe_pips -lt 0) -or ([double]$_.mae_pips -lt 0)
})

$summary = [ordered]@{
    RunId = $RunId
    Candidates = $candidates.Count
    Decisions = $decisions.Count
    Outcomes = $outcomes.Count
    RuntimeErrors = $errors.Count
    DuplicateCandidates = $duplicateCandidates.Count
    DuplicateDecisions = $duplicateDecisions.Count
    DuplicateOutcomes = $duplicateOutcomes.Count
    MissingDecisions = $missingDecisions.Count
    MissingOutcomes = $missingOutcomes.Count
    OrphanDecisions = $orphanDecisions.Count
    OrphanOutcomes = $orphanOutcomes.Count
    InvalidOutcomeCodes = $invalidOutcomeCodes.Count
    InvalidLabels = $invalidLabels.Count
    NegativeExcursions = $negativeExcursions.Count
}

[pscustomobject]$summary | Format-List

$outcomes |
    Group-Object outcome |
    Sort-Object Name |
    Select-Object Name, Count |
    Format-Table -AutoSize

$failed = @(
    $duplicateCandidates.Count,
    $duplicateDecisions.Count,
    $duplicateOutcomes.Count,
    $missingDecisions.Count,
    $missingOutcomes.Count,
    $orphanDecisions.Count,
    $orphanOutcomes.Count,
    $invalidOutcomeCodes.Count,
    $invalidLabels.Count,
    $negativeExcursions.Count,
    $errors.Count
) | Where-Object { $_ -gt 0 }

if ($failed.Count -gt 0) {
    throw 'Outcome CSV validation failed. Review the counts above.'
}

Write-Host 'Outcome CSV validation passed.' -ForegroundColor Green
