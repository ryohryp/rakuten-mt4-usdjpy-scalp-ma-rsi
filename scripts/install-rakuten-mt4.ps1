[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TerminalDataPath,

    [switch]$SkipPreset
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-TerminalMql4Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ((Split-Path -Leaf $resolved) -ieq 'MQL4') {
        return $resolved
    }

    return Join-Path $resolved 'MQL4'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceMql4 = Join-Path $repoRoot 'src\MQL4'
$sourceExpert = Join-Path $sourceMql4 'Experts\USDJPY_Scalp_MA_RSI.mq4'
$sourceIncludes = Join-Path $sourceMql4 'Include\AIData'
$sourcePreset = Join-Path $repoRoot 'presets\usdjpy_m5_default.set'

if (-not (Test-Path -LiteralPath $sourceExpert -PathType Leaf)) {
    throw "EA source was not found: $sourceExpert"
}
if (-not (Test-Path -LiteralPath $sourceIncludes -PathType Container)) {
    throw "AIData include directory was not found: $sourceIncludes"
}

$targetMql4 = Resolve-TerminalMql4Path -Path $TerminalDataPath
$targetExperts = Join-Path $targetMql4 'Experts'
$targetIncludes = Join-Path $targetMql4 'Include\AIData'
$targetPresets = Join-Path $targetMql4 'Presets'

New-Item -ItemType Directory -Path $targetExperts -Force | Out-Null
New-Item -ItemType Directory -Path $targetIncludes -Force | Out-Null

Copy-Item -LiteralPath $sourceExpert -Destination (Join-Path $targetExperts 'USDJPY_Scalp_MA_RSI.mq4') -Force
Copy-Item -Path (Join-Path $sourceIncludes '*.mqh') -Destination $targetIncludes -Force

if (-not $SkipPreset) {
    if (-not (Test-Path -LiteralPath $sourcePreset -PathType Leaf)) {
        throw "Preset was not found: $sourcePreset"
    }
    New-Item -ItemType Directory -Path $targetPresets -Force | Out-Null
    Copy-Item -LiteralPath $sourcePreset -Destination (Join-Path $targetPresets 'usdjpy_m5_default.set') -Force
}

$requiredFiles = @(
    (Join-Path $targetExperts 'USDJPY_Scalp_MA_RSI.mq4'),
    (Join-Path $targetIncludes 'Types.mqh'),
    (Join-Path $targetIncludes 'RunContext.mqh'),
    (Join-Path $targetIncludes 'CsvWriter.mqh'),
    (Join-Path $targetIncludes 'SignalLogger.mqh'),
    (Join-Path $targetIncludes 'TradeResultLogger.mqh')
)

$missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Installation verification failed. Missing files:`n$($missing -join "`n")"
}

Write-Host ''
Write-Host 'Rakuten MT4 files installed successfully.' -ForegroundColor Green
Write-Host "MQL4 path: $targetMql4"
Write-Host "EA:        $($requiredFiles[0])"
Write-Host "Includes:  $targetIncludes"
if (-not $SkipPreset) {
    Write-Host "Preset:    $(Join-Path $targetPresets 'usdjpy_m5_default.set')"
}
Write-Host ''
Write-Host 'Open MetaEditor from the same Rakuten MT4 terminal and compile USDJPY_Scalp_MA_RSI.mq4.'
