[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Actions,
    [switch]$All,
    [switch]$Low,
    [switch]$DryRun,
    [switch]$Yes,
    [int]$TempDays = 7,
    [switch]$List
)

$ErrorActionPreference = "Continue"

function Format-Bytes {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return "0 B" }
    $units = "B", "KB", "MB", "GB", "TB"
    $i = 0
    $v = [double]$Bytes
    while ($v -ge 1024 -and $i -lt $units.Count - 1) { $v /= 1024; $i++ }
    return "{0:N1} {1}" -f $v, $units[$i]
}

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Get-CFreeBytes {
    (Get-Volume -DriveLetter C -ErrorAction SilentlyContinue).SizeRemaining
}

function Confirm-Or-Exit {
    param([string]$Prompt)
    if ($Yes) { return $true }
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -match '^(y|yes)$')
}

# ----------------- Actions -----------------

function Action-RecycleBin {
    $sizeBefore = 0
    $bin = "C:\`$Recycle.Bin"
    if (Test-Path -LiteralPath $bin) {
        $sizeBefore = Get-DirSize -Path $bin
    }
    Write-Host "  Current Recycle Bin size: $(Format-Bytes $sizeBefore)"
    if ($DryRun) { return $sizeBefore }
    if ($sizeBefore -eq 0) { Write-Host "  Nothing to empty."; return 0 }
    if (-not (Confirm-Or-Exit "Empty Recycle Bin?")) { Write-Host "  Skipped."; return 0 }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    return $sizeBefore
}

function Action-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "  Docker CLI not found. Skipping."
        return 0
    }
    Write-Host "  docker system df:"
    & docker system df 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($DryRun) { return 0 }
    if (-not (Confirm-Or-Exit "Run 'docker builder prune -f'?")) { Write-Host "  Skipped."; return 0 }
    $output = & docker builder prune -f 2>&1
    $output | ForEach-Object { Write-Host "    $_" }
    $totalLine = $output | Where-Object { $_ -match '^Total:\s*([\d\.]+)\s*([KMGT]?B)' }
    if ($totalLine) {
        $value = [double]$matches[1]
        $unit = $matches[2]
        $bytes = switch ($unit) {
            "B"  { [int64]$value }
            "KB" { [int64]($value * 1KB) }
            "MB" { [int64]($value * 1MB) }
            "GB" { [int64]($value * 1GB) }
            "TB" { [int64]($value * 1TB) }
            default { 0 }
        }
        return $bytes
    }
    return 0
}

function Action-VSCodeCache {
    $vsc = "$env:USERPROFILE\AppData\Roaming\Code"
    if (-not (Test-Path -LiteralPath $vsc)) {
        Write-Host "  VS Code Roaming not found. Skipping."
        return 0
    }
    if (Get-Process -Name "Code" -ErrorAction SilentlyContinue) {
        Write-Host "  WARN: VS Code is running. Locked files will be skipped."
    }
    $targets = @("Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache")
    $totalBefore = 0
    foreach ($d in $targets) {
        $p = Join-Path $vsc $d
        if (Test-Path -LiteralPath $p) {
            $b = Get-DirSize -Path $p
            $totalBefore += $b
            Write-Host ("    {0,-22} {1}" -f $d, (Format-Bytes $b))
        }
    }
    Write-Host "  Total cleanable: $(Format-Bytes $totalBefore)"
    if ($DryRun) { return $totalBefore }
    if ($totalBefore -eq 0) { return 0 }
    if (-not (Confirm-Or-Exit "Delete contents of these VS Code cache folders?")) { Write-Host "  Skipped."; return 0 }
    $totalAfter = 0
    foreach ($d in $targets) {
        $p = Join-Path $vsc $d
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            $totalAfter += Get-DirSize -Path $p
        }
    }
    return [int64]($totalBefore - $totalAfter)
}

function Action-Temp {
    $t = "$env:USERPROFILE\AppData\Local\Temp"
    if (-not (Test-Path -LiteralPath $t)) { return 0 }
    $cutoff = (Get-Date).AddDays(-$TempDays)
    $candidates = Get-ChildItem -LiteralPath $t -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }
    $beforeBytes = ($candidates | Measure-Object Length -Sum).Sum
    if ($null -eq $beforeBytes) { $beforeBytes = 0 }
    Write-Host "  Temp files older than $TempDays days: $($candidates.Count) files, $(Format-Bytes $beforeBytes)"
    if ($DryRun) { return $beforeBytes }
    if ($candidates.Count -eq 0) { return 0 }
    if (-not (Confirm-Or-Exit "Delete these files?")) { Write-Host "  Skipped."; return 0 }
    $deleted = 0
    $skipped = 0
    $freed = [int64]0
    foreach ($f in $candidates) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++; $freed += $f.Length }
        catch { $skipped++ }
    }
    Write-Host "  Deleted $deleted, locked-skipped $skipped"
    return $freed
}

function Action-ClaudeVM {
    $bundle = "$env:USERPROFILE\AppData\Roaming\Claude\vm_bundles\claudevm.bundle"
    if (-not (Test-Path -LiteralPath $bundle)) {
        Write-Host "  Claude VM bundle not found (Cowork was never initialised). Skipping."
        return 0
    }
    $size = Get-DirSize -Path $bundle
    Write-Host "  Bundle size: $(Format-Bytes $size)"
    Write-Host "  Path: $bundle"
    Write-Host "  WARNING: Deletes Claude Cowork VM. Claude Code will rebuild the bundle on next /cowork use."
    if (Get-Process -Name "Claude" -ErrorAction SilentlyContinue) {
        Write-Host "  Note: Claude Desktop is running. Bundle is usually only locked while a Cowork session is active."
    }
    if ($DryRun) { return $size }
    if (-not (Confirm-Or-Exit "Delete the Claude Cowork VM bundle?")) { Write-Host "  Skipped."; return 0 }
    Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction Continue
    if (Test-Path -LiteralPath $bundle) {
        Write-Host "  Partial delete - some files were locked."
        $remain = Get-DirSize -Path $bundle
        return [int64]($size - $remain)
    }
    return $size
}

function Action-WslCompact {
    Write-Host "  WSL VHDX compact requires:"
    Write-Host "    1. Administrator privileges (diskpart)"
    Write-Host "    2. fstrim inside each Linux distro to mark blocks reclaimable"
    Write-Host ""
    Write-Host "  See CLEANUP.md or run tools/compact-wsl.cmd (right-click, Run as administrator)."
    Write-Host ""
    $script = Join-Path $PSScriptRoot "compact-wsl.cmd"
    if (Test-Path -LiteralPath $script) {
        Write-Host "  Compactor script is at: $script"
    } else {
        Write-Host "  WARNING: compact-wsl.cmd is missing from the project root."
    }
    return 0
}

function Action-RegenerateReport {
    $scan = Join-Path $PSScriptRoot "collect-storage.ps1"
    if (-not (Test-Path -LiteralPath $scan)) { Write-Host "  collect-storage.ps1 not found."; return 0 }
    Write-Host "  Running collect-storage.ps1..."
    & $scan
    return 0
}

# ----------------- Action registry -----------------

$Registry = [ordered]@{
    "recycle-bin"  = @{ Risk = "low";    Title = "Empty Recycle Bin";                  Run = { Action-RecycleBin } }
    "docker"       = @{ Risk = "low";    Title = "Prune Docker build cache";           Run = { Action-Docker } }
    "vscode-cache" = @{ Risk = "low";    Title = "Clear VS Code Roaming caches";       Run = { Action-VSCodeCache } }
    "temp"         = @{ Risk = "low";    Title = "Delete %TEMP% files older than $TempDays days"; Run = { Action-Temp } }
    "claude-vm"    = @{ Risk = "medium"; Title = "Delete Claude Cowork VM bundle";     Run = { Action-ClaudeVM } }
    "wsl-compact"  = @{ Risk = "info";   Title = "How to compact WSL VHDX";            Run = { Action-WslCompact } }
    "report"       = @{ Risk = "low";    Title = "Re-run collect-storage.ps1";         Run = { Action-RegenerateReport } }
}

function Show-Menu {
    Write-Host ""
    Write-Host "Available cleanup actions:"
    Write-Host ""
    foreach ($key in $Registry.Keys) {
        $entry = $Registry[$key]
        Write-Host ("  {0,-14} [{1,-6}] {2}" -f $key, $entry.Risk, $entry.Title)
    }
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\cleanup-storage.ps1 -Low                         # all low-risk actions"
    Write-Host "  .\cleanup-storage.ps1 -All                         # everything (with prompts)"
    Write-Host "  .\cleanup-storage.ps1 docker vscode-cache temp     # specific actions"
    Write-Host "  .\cleanup-storage.ps1 -All -DryRun                 # show what would be freed"
    Write-Host "  .\cleanup-storage.ps1 -All -Yes                    # skip confirmation prompts"
    Write-Host ""
}

# ----------------- Dispatch -----------------

if ($List -or (-not $Actions -and -not $All -and -not $Low)) {
    Show-Menu
    exit 0
}

$selected = New-Object System.Collections.Generic.List[string]
if ($All) {
    foreach ($k in $Registry.Keys) { [void]$selected.Add($k) }
} elseif ($Low) {
    foreach ($k in $Registry.Keys) {
        if ($Registry[$k].Risk -eq "low") { [void]$selected.Add($k) }
    }
}
if ($Actions) {
    foreach ($a in $Actions) {
        if (-not $Registry.Contains($a)) {
            Write-Host "Unknown action: $a"
            Show-Menu
            exit 1
        }
        if (-not $selected.Contains($a)) { [void]$selected.Add($a) }
    }
}

if ($selected.Count -eq 0) {
    Show-Menu
    exit 0
}

$cFreeBefore = Get-CFreeBytes
Write-Host ""
Write-Host ("C: free before: $(Format-Bytes $cFreeBefore)")
if ($DryRun) { Write-Host "DRY RUN - no files will be deleted." }
Write-Host ""

$summary = New-Object System.Collections.Generic.List[object]
foreach ($key in $selected) {
    $entry = $Registry[$key]
    Write-Host "==> [$key] $($entry.Title) (risk: $($entry.Risk))"
    $freed = & $entry.Run
    if ($null -eq $freed) { $freed = 0 }
    [void]$summary.Add([PSCustomObject]@{
        action = $key
        freed  = [int64]$freed
    })
    Write-Host "    Freed: $(Format-Bytes $freed)"
    Write-Host ""
}

$cFreeAfter = Get-CFreeBytes
$cDelta = $cFreeAfter - $cFreeBefore
Write-Host "================================ Summary ================================"
foreach ($row in $summary) {
    Write-Host ("  {0,-14} {1}" -f $row.action, (Format-Bytes $row.freed))
}
Write-Host ("  {0,-14} {1}" -f "TOTAL (logical)", (Format-Bytes ($summary | Measure-Object freed -Sum).Sum))
Write-Host ""
Write-Host ("C: free after:  $(Format-Bytes $cFreeAfter)")
Write-Host ("C: net change:  $(Format-Bytes $cDelta)")
Write-Host ""
Write-Host "Tip: run '.\cleanup-storage.ps1 report' to refresh the dashboard data."
