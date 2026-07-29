[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TerminalDataPath,

    [ValidateRange(1, 60)]
    [int]$RetryCount = 5,

    [ValidateRange(100, 10000)]
    [int]$RetryDelayMilliseconds = 1000,

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

function Test-SameFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        return $false
    }

    try {
        $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        return $sourceHash -eq $destinationHash
    }
    catch {
        return $false
    }
}

function Get-Mt4LockHint {
    $running = @()
    foreach ($name in @('metaeditor', 'terminal')) {
        $running += @(Get-Process -Name $name -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ProcessName -Unique)
    }

    $running = @($running | Sort-Object -Unique)
    if ($running.Count -gt 0) {
        return "Running process(es): $($running -join ', '). Close MetaEditor first; if the file remains locked, close Rakuten MT4 as well."
    }

    return 'Close MetaEditor and Rakuten MT4, then run the installer again.'
}

function Copy-FileWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-SameFileContent -Source $Source -Destination $Destination) {
        Write-Host "Unchanged: $Destination"
        return
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            Write-Host "Installed: $Destination"
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $RetryCount) {
                $hint = Get-Mt4LockHint
                throw "Could not replace the MT4 file after $RetryCount attempt(s): $Destination`n$hint`nLast error: $($_.Exception.Message)"
            }

            Write-Warning "File is locked. Retry $attempt/$RetryCount after $RetryDelayMilliseconds ms: $Destination"
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
}

function Remove-FileWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force
            Write-Host "Invalidated stale binary: $Path" -ForegroundColor Yellow
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $RetryCount) {
                $hint = Get-Mt4LockHint
                throw "Could not invalidate the stale MT4 binary after $RetryCount attempt(s): $Path`n$hint`nLast error: $($_.Exception.Message)"
            }

            Write-Warning "Compiled EA is locked. Retry $attempt/$RetryCount after $RetryDelayMilliseconds ms: $Path"
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
}

function Get-CompilationFingerprint {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $fingerprintLines = @($Paths |
        Sort-Object |
        ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
            "{0}:{1}" -f (Split-Path -Leaf $_), $hash
        })

    $material = $fingerprintLines -join "`n"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
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

$includeFiles = @(Get-ChildItem -LiteralPath $sourceIncludes -Filter '*.mqh' -File | Sort-Object Name)
if ($includeFiles.Count -eq 0) {
    throw "No AIData include files were found: $sourceIncludes"
}

$compilationSources = @($sourceExpert) + @($includeFiles | ForEach-Object FullName)
$compilationFingerprint = Get-CompilationFingerprint -Paths $compilationSources

$targetMql4 = Resolve-TerminalMql4Path -Path $TerminalDataPath
$targetExperts = Join-Path $targetMql4 'Experts'
$targetIncludes = Join-Path $targetMql4 'Include\AIData'
$targetPresets = Join-Path $targetMql4 'Presets'
$targetExpertMq4 = Join-Path $targetExperts 'USDJPY_Scalp_MA_RSI.mq4'
$targetExpertEx4 = Join-Path $targetExperts 'USDJPY_Scalp_MA_RSI.ex4'
$targetFingerprint = Join-Path $targetExperts '.USDJPY_Scalp_MA_RSI.compile-source.sha256'

$previousFingerprint = ''
if (Test-Path -LiteralPath $targetFingerprint -PathType Leaf) {
    $previousFingerprint = (Get-Content -LiteralPath $targetFingerprint -Raw).Trim()
}
$compilationRequired = $previousFingerprint -ne $compilationFingerprint

New-Item -ItemType Directory -Path $targetExperts -Force | Out-Null
New-Item -ItemType Directory -Path $targetIncludes -Force | Out-Null

Copy-FileWithRetry `
    -Source $sourceExpert `
    -Destination $targetExpertMq4

foreach ($includeFile in $includeFiles) {
    Copy-FileWithRetry `
        -Source $includeFile.FullName `
        -Destination (Join-Path $targetIncludes $includeFile.Name)
}

if ($compilationRequired) {
    Remove-FileWithRetry -Path $targetExpertEx4
    Set-Content -LiteralPath $targetFingerprint -Value $compilationFingerprint -Encoding ASCII
}

if (-not $SkipPreset) {
    if (-not (Test-Path -LiteralPath $sourcePreset -PathType Leaf)) {
        throw "Preset was not found: $sourcePreset"
    }
    New-Item -ItemType Directory -Path $targetPresets -Force | Out-Null
    Copy-FileWithRetry `
        -Source $sourcePreset `
        -Destination (Join-Path $targetPresets 'usdjpy_m5_default.set')
}

$requiredFiles = @(
    $targetExpertMq4,
    (Join-Path $targetIncludes 'Types.mqh'),
    (Join-Path $targetIncludes 'RunContext.mqh'),
    (Join-Path $targetIncludes 'CsvWriter.mqh'),
    (Join-Path $targetIncludes 'OutcomeTracker.mqh'),
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
if ($compilationRequired) {
    Write-Host 'Source changes were detected. The old EX4 was invalidated.' -ForegroundColor Yellow
    Write-Host 'Open MetaEditor from the same Rakuten MT4 terminal and compile USDJPY_Scalp_MA_RSI.mq4 before testing.' -ForegroundColor Yellow
}
else {
    Write-Host 'Source fingerprint is unchanged. Existing EX4 was left intact.'
}
