param(
    [string]$OutputPath = ".\Report\storage-report.json",
    [int]$Top = 20,
    [int64]$LargeFileThresholdGB = 1,
    [switch]$DeepScan,
    [switch]$NoCache,
    [int]$CacheTtlMinutes = 360,
    [switch]$NoProgress,
    [switch]$NoHistory,
    [int]$HistoryRetention = 30,
    [switch]$NoParallel,
    [int]$ParallelThrottle = 4
)

$ErrorActionPreference = "Continue"

$script:scanErrors     = [System.Collections.Generic.List[object]]::new()
$script:cache          = @{}
$script:newCache       = @{}
$script:cacheFile      = $null
$script:cacheHits      = 0
$script:cacheMisses    = 0
$script:supportsParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and (-not $NoParallel)

function Add-ScanError {
    param([string]$Stage, [string]$Path, [string]$Message)
    [void]$script:scanErrors.Add([PSCustomObject]@{
        stage   = $Stage
        path    = $Path
        message = $Message
    })
}

function ConvertTo-Gb {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes) { return 0 }
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-PathMtimeTicks {
    param([string]$Path)
    try {
        return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTimeUtc.Ticks
    } catch {
        return 0
    }
}

function Initialize-Cache {
    param([string]$CacheFile)
    $script:cacheFile = $CacheFile
    if ($NoCache) { return }
    if (-not (Test-Path -LiteralPath $CacheFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $CacheFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $obj.PSObject.Properties) {
            $script:cache[$prop.Name] = $prop.Value
        }
    } catch {
        Add-ScanError -Stage "cache-load" -Path $CacheFile -Message $_.Exception.Message
    }
}

function Save-Cache {
    if ($NoCache -or -not $script:cacheFile) { return }
    try {
        $dir = Split-Path -Parent $script:cacheFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        ($script:newCache | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $script:cacheFile -Encoding UTF8
    } catch {
        Add-ScanError -Stage "cache-save" -Path $script:cacheFile -Message $_.Exception.Message
    }
}

function Get-CachedSize {
    param([string]$Path)
    if ($NoCache) { return $null }
    $key = $Path.ToLowerInvariant()
    if (-not $script:cache.ContainsKey($key)) { return $null }
    $entry = $script:cache[$key]
    try {
        $age = (Get-Date) - [datetime]$entry.cachedAt
        if ($age.TotalMinutes -gt $CacheTtlMinutes) { return $null }
        if ([int64]$entry.mtimeTicks -ne (Get-PathMtimeTicks -Path $Path)) { return $null }
        return [int64]$entry.bytes
    } catch {
        return $null
    }
}

function Update-CacheEntry {
    param([string]$Path, [int64]$Bytes)
    $key = $Path.ToLowerInvariant()
    $script:newCache[$key] = [PSCustomObject]@{
        bytes      = $Bytes
        cachedAt   = (Get-Date).ToString("o")
        mtimeTicks = Get-PathMtimeTicks -Path $Path
    }
}

function Measure-DirectorySizeRaw {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $err = $null
    $sum = [int64]0
    Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable err |
        ForEach-Object { $sum += [int64]$_.Length }
    foreach ($e in $err) {
        Add-ScanError -Stage "size" -Path $Path -Message $e.Exception.Message
    }
    return [int64]$sum
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $cached = Get-CachedSize -Path $Path
    if ($null -ne $cached) {
        $script:cacheHits++
        Update-CacheEntry -Path $Path -Bytes $cached
        return $cached
    }
    $script:cacheMisses++
    $size = Measure-DirectorySizeRaw -Path $Path
    Update-CacheEntry -Path $Path -Bytes $size
    return $size
}

function Invoke-PathSizes {
    param(
        [string[]]$Paths,
        [string]$Activity = "Measuring directories"
    )
    $result = @{}
    if (-not $Paths -or $Paths.Count -eq 0) { return $result }

    $misses = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        $hit = Get-CachedSize -Path $p
        if ($null -ne $hit) {
            $result[$p] = [int64]$hit
            $script:cacheHits++
            Update-CacheEntry -Path $p -Bytes $hit
        } else {
            [void]$misses.Add($p)
        }
    }

    if ($misses.Count -eq 0) { return $result }

    if ($script:supportsParallel -and $misses.Count -gt 1) {
        $sized = $misses | ForEach-Object -ThrottleLimit $ParallelThrottle -Parallel {
            $p = $_
            $sum = [int64]0
            if (Test-Path -LiteralPath $p) {
                Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $sum += [int64]$_.Length }
            }
            [PSCustomObject]@{ path = $p; bytes = [int64]$sum }
        }
        foreach ($r in $sized) {
            $result[$r.path] = [int64]$r.bytes
            $script:cacheMisses++
            Update-CacheEntry -Path $r.path -Bytes $r.bytes
        }
    } else {
        $total = $misses.Count
        $i = 0
        foreach ($p in $misses) {
            $i++
            if (-not $NoProgress -and $total -gt 1) {
                $percent = [int](($i / $total) * 100)
                Write-Progress -Activity $Activity -Status $p -PercentComplete $percent -CurrentOperation "$i of $total"
            }
            $size = Measure-DirectorySizeRaw -Path $p
            $result[$p] = $size
            $script:cacheMisses++
            Update-CacheEntry -Path $p -Bytes $size
        }
        if (-not $NoProgress -and $total -gt 1) {
            Write-Progress -Activity $Activity -Completed
        }
    }

    return $result
}

function Get-ChildBreakdown {
    param(
        [string]$Path,
        [int]$Limit = 20,
        [string]$Activity = "Drilldown"
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $children = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $children) { return @() }

    $dirPaths = $children | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName }
    $dirSizes = if ($dirPaths) { Invoke-PathSizes -Paths $dirPaths -Activity $Activity } else { @{} }

    $children |
        ForEach-Object {
            $size = if ($_.PSIsContainer) {
                if ($dirSizes.ContainsKey($_.FullName)) { [int64]$dirSizes[$_.FullName] } else { [int64]0 }
            } else {
                [int64]$_.Length
            }
            [PSCustomObject]@{
                name  = $_.Name
                path  = $_.FullName
                type  = if ($_.PSIsContainer) { "directory" } else { "file" }
                bytes = $size
                gb    = ConvertTo-Gb $size
            }
        } |
        Sort-Object bytes -Descending |
        Select-Object -First $Limit
}

function Get-DriveRisk {
    param([double]$UsedPercent)
    if ($UsedPercent -ge 90) { return "critical" }
    if ($UsedPercent -ge 80) { return "warning" }
    return "healthy"
}

function Parse-DockerSize {
    param([string]$Token)
    if ($Token -match '^\s*(\d+(?:\.\d+)?)\s*(B|kB|KB|MB|GB|TB)\s*$') {
        $value = [double]$matches[1]
        switch ($matches[2].ToUpperInvariant()) {
            "B"  { return [int64]$value }
            "KB" { return [int64]($value * 1KB) }
            "MB" { return [int64]($value * 1MB) }
            "GB" { return [int64]($value * 1GB) }
            "TB" { return [int64]($value * 1TB) }
        }
    }
    return $null
}

function Get-DockerInfo {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            available   = $false
            summary     = @()
            reclaimable = $null
            notes       = "Docker CLI was not found in PATH."
        }
    }

    $summary = @()
    $reclaimableBytes = [int64]0
    $reclaimableRows = New-Object System.Collections.Generic.List[object]

    try {
        $summary = & docker system df 2>$null | ForEach-Object { "$_" }
    } catch {
        Add-ScanError -Stage "docker" -Path "docker system df" -Message $_.Exception.Message
    }

    foreach ($line in $summary) {
        # Match TYPE then RECLAIMABLE token (which always has "(N%)" suffix)
        if ($line -match '^(Images|Containers|Local Volumes|Build Cache)\s+\S+(?:\s+\S+)*?\s+(\d+(?:\.\d+)?\s*[KMGT]?B)\s*\(\s*\d+%') {
            $type = $matches[1]
            $bytes = Parse-DockerSize $matches[2]
            if ($null -ne $bytes) {
                $reclaimableBytes += $bytes
                [void]$reclaimableRows.Add([PSCustomObject]@{
                    type  = $type
                    bytes = [int64]$bytes
                    gb    = ConvertTo-Gb $bytes
                })
            }
        }
    }

    $reclaimable = if ($reclaimableRows.Count -gt 0) {
        [PSCustomObject]@{
            bytes = [int64]$reclaimableBytes
            gb    = ConvertTo-Gb $reclaimableBytes
            rows  = $reclaimableRows
            note  = "Approx. recoverable via docker system prune -a --volumes"
        }
    } else { $null }

    return [PSCustomObject]@{
        available   = $true
        summary     = $summary
        reclaimable = $reclaimable
        notes       = "docker builder prune removes build cache; docker system prune -a removes unused images and containers."
    }
}

function Update-History {
    param(
        [string]$HistoryFile,
        [object]$Snapshot
    )
    if ($NoHistory) { return @() }

    $existing = @()
    if (Test-Path -LiteralPath $HistoryFile) {
        try {
            $raw = Get-Content -LiteralPath $HistoryFile -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                $existing = if ($parsed -is [array]) { $parsed } else { @($parsed) }
            }
        } catch {
            Add-ScanError -Stage "history-load" -Path $HistoryFile -Message $_.Exception.Message
        }
    }

    $combined = @($existing) + @($Snapshot)
    if ($combined.Count -gt $HistoryRetention) {
        $combined = $combined | Select-Object -Last $HistoryRetention
    }

    try {
        $dir = Split-Path -Parent $HistoryFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        ($combined | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $HistoryFile -Encoding UTF8
    } catch {
        Add-ScanError -Stage "history-save" -Path $HistoryFile -Message $_.Exception.Message
    }

    return $combined
}

function Get-KnownPathDef {
    param(
        [string]$Label,
        [string]$Path,
        [string]$Category,
        [string]$CleaningNotes,
        [bool]$UsuallySafeToClean
    )
    [PSCustomObject]@{
        label              = $Label
        path               = $Path
        category           = $Category
        cleaningNotes      = $CleaningNotes
        usuallySafeToClean = $UsuallySafeToClean
    }
}

# ---------- Begin scan ----------

$scanStart = Get-Date

$resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path (Get-Location) $OutputPath
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    $outputDirectory = Get-Location
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

Initialize-Cache -CacheFile (Join-Path $outputDirectory "scan-cache.json")

$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

$volumes = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveLetter } |
    Sort-Object DriveLetter |
    ForEach-Object {
        $used = $_.Size - $_.SizeRemaining
        $usedPercent = if ($_.Size -gt 0) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
        [PSCustomObject]@{
            driveLetter = "$($_.DriveLetter):"
            label       = $_.FileSystemLabel
            fileSystem  = $_.FileSystem
            totalBytes  = [int64]$_.Size
            usedBytes   = [int64]$used
            freeBytes   = [int64]$_.SizeRemaining
            totalGb     = ConvertTo-Gb $_.Size
            usedGb      = ConvertTo-Gb $used
            freeGb      = ConvertTo-Gb $_.SizeRemaining
            usedPercent = $usedPercent
            health      = Get-DriveRisk $usedPercent
        }
    }

$systemFiles = @(
    "C:\pagefile.sys",
    "C:\hiberfil.sys",
    "C:\swapfile.sys"
) | ForEach-Object {
    $item = Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue
    if ($item) {
        [PSCustomObject]@{
            name          = $item.Name
            path          = $item.FullName
            bytes         = [int64]$item.Length
            gb            = ConvertTo-Gb $item.Length
            cleaningNotes = switch ($item.Name) {
                "hiberfil.sys" { "Can be removed by disabling hibernation with: powercfg /h off" }
                "pagefile.sys" { "Virtual memory file. Do not delete manually; tune only via Windows settings." }
                "swapfile.sys" { "Windows managed swap file. Do not delete manually." }
                default { "Windows managed file." }
            }
        }
    }
}

$profilePath = $env:USERPROFILE

$knownDefs = @(
    Get-KnownPathDef "AppData Local"        "$profilePath\AppData\Local"               "app-data"  "Application caches, VM files, browser data, and local app storage." $false
    Get-KnownPathDef "AppData Roaming"      "$profilePath\AppData\Roaming"             "app-data"  "Application profiles and synced settings. Clean app-specific caches only." $false
    Get-KnownPathDef "Downloads"            "$profilePath\Downloads"                   "user-files" "Usually safe to review, archive, or move to another drive." $true
    Get-KnownPathDef "Documents"            "$profilePath\Documents"                   "user-files" "Review manually; move large archives/projects to a data drive." $false
    Get-KnownPathDef "Desktop"              "$profilePath\Desktop"                     "user-files" "Review manually; often contains temporary work files." $false
    Get-KnownPathDef "Pictures"             "$profilePath\Pictures"                    "user-files" "Move media libraries to a data drive if large." $false
    Get-KnownPathDef "Videos"               "$profilePath\Videos"                      "user-files" "Move media libraries to a data drive if large." $false
    Get-KnownPathDef "Temp"                 "$profilePath\AppData\Local\Temp"          "cache"     "Usually safe to clean after closing applications." $true
    Get-KnownPathDef "Chrome"               "$profilePath\AppData\Local\Google\Chrome" "browser"   "Use Chrome clear browsing data; do not delete the whole profile blindly." $false
    Get-KnownPathDef "Docker Desktop"       "$profilePath\AppData\Local\Docker"        "developer" "Use docker builder prune/system prune instead of deleting vhdx files manually." $false
    Get-KnownPathDef "WSL local disk"       "$profilePath\AppData\Local\wsl"           "developer" "Clean Linux distro contents first, then compact the VHDX." $false
    Get-KnownPathDef "VS Code roaming data" "$profilePath\AppData\Roaming\Code"        "developer" "CachedExtensionVSIXs, Cache, and CachedData are common cleanup targets." $false
    Get-KnownPathDef "Windows recycle bin"  "C:\`$Recycle.Bin"                         "cleanup"   "Usually safe to empty after reviewing deleted files." $true
)

if ($DeepScan) {
    $knownDefs = @(
        Get-KnownPathDef "User profile" $profilePath "profile" "Largest user-owned area. Drill down before deleting anything." $false
    ) + $knownDefs
}

$knownPathStrings = $knownDefs |
    Where-Object { Test-Path -LiteralPath $_.path } |
    ForEach-Object { $_.path }

$knownSizes = Invoke-PathSizes -Paths $knownPathStrings -Activity "Measuring known areas"

$knownPaths = $knownDefs | ForEach-Object {
    $bytes = if ($knownSizes.ContainsKey($_.path)) { [int64]$knownSizes[$_.path] } else { [int64]0 }
    [PSCustomObject]@{
        label              = $_.label
        path               = $_.path
        category           = $_.category
        bytes              = $bytes
        gb                 = ConvertTo-Gb $bytes
        usuallySafeToClean = $_.usuallySafeToClean
        cleaningNotes      = $_.cleaningNotes
    }
}

# Root C:\ top-level breakdown is now ON by default (cheap top-level only).
# -DeepScan adds the inside-directory deep walk which is the slow part.
$rootBreakdown    = Get-ChildBreakdown -Path "C:\"                         -Limit $Top -Activity "C:\ top level"
$localBreakdown   = Get-ChildBreakdown -Path "$profilePath\AppData\Local"  -Limit $Top -Activity "AppData Local children"
$roamingBreakdown = Get-ChildBreakdown -Path "$profilePath\AppData\Roaming" -Limit $Top -Activity "AppData Roaming children"

$wslFiles = Get-ChildItem -LiteralPath "$profilePath\AppData\Local\wsl" -Force -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First 10 |
    ForEach-Object {
        [PSCustomObject]@{
            name  = $_.Name
            path  = $_.FullName
            bytes = [int64]$_.Length
            gb    = ConvertTo-Gb $_.Length
        }
    }

$largeFiles = @()
if ($DeepScan) {
    $threshold = $LargeFileThresholdGB * 1GB
    if (-not $NoProgress) {
        Write-Progress -Activity "Deep scan: scanning for large files" -Status $profilePath
    }
    $largeFiles = Get-ChildItem -LiteralPath $profilePath -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $threshold } |
        Sort-Object Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [PSCustomObject]@{
                name  = $_.Name
                path  = $_.FullName
                bytes = [int64]$_.Length
                gb    = ConvertTo-Gb $_.Length
            }
        }
    if (-not $NoProgress) {
        Write-Progress -Activity "Deep scan: scanning for large files" -Completed
    }
}

$docker = Get-DockerInfo

$recommendations = @(
    [PSCustomObject]@{
        priority = 1
        title    = "Empty Recycle Bin"
        command  = "Open Recycle Bin and choose Empty Recycle Bin"
        risk     = "low"
        reason   = "Deleted files still occupy disk space until the bin is emptied."
    },
    [PSCustomObject]@{
        priority = 2
        title    = "Clean temporary files"
        command  = "Windows Settings > System > Storage > Temporary files"
        risk     = "low"
        reason   = "Uses Windows supported cleanup flow and avoids deleting active application data."
    },
    [PSCustomObject]@{
        priority = 3
        title    = "Prune Docker build cache"
        command  = "docker builder prune"
        risk     = "low-medium"
        reason   = "Removes unused image build cache; future Docker builds may take longer."
    },
    [PSCustomObject]@{
        priority = 4
        title    = "Compact WSL virtual disk after Linux cleanup"
        command  = "wsl --shutdown, then compact the ext4.vhdx from Windows"
        risk     = "medium"
        reason   = "WSL VHDX files do not always shrink after files are deleted inside Linux."
    },
    [PSCustomObject]@{
        priority = 5
        title    = "Disable hibernation if unused"
        command  = "powercfg /h off"
        risk     = "medium"
        reason   = "Removes hiberfil.sys but disables Hibernate and Fast Startup behavior."
    }
)

if ($docker.reclaimable -and $docker.reclaimable.bytes -gt 0) {
    $recommendations = ,([PSCustomObject]@{
        priority = 0
        title    = "Reclaim Docker space"
        command  = "docker system prune -a --volumes"
        risk     = "medium"
        reason   = "Docker reports approx. $($docker.reclaimable.gb) GB reclaimable across images, containers, volumes, and build cache."
    }) + $recommendations
}

$scanEnd = Get-Date

$report = [PSCustomObject]@{
    schemaVersion   = "2.0"
    generatedAt     = $scanEnd.ToString("o")
    host            = [PSCustomObject]@{
        computerName = $env:COMPUTERNAME
        userName     = $env:USERNAME
        osCaption    = if ($os) { $os.Caption } else { "Unknown" }
        osVersion    = if ($os) { $os.Version } else { "" }
        architecture = if ($os) { $os.OSArchitecture } else { "" }
        manufacturer = if ($computer) { $computer.Manufacturer } else { "" }
        model        = if ($computer) { $computer.Model } else { "" }
    }
    scan            = [PSCustomObject]@{
        top                  = $Top
        deepScan             = [bool]$DeepScan
        largeFileThresholdGb = $LargeFileThresholdGB
        adminRequired        = $false
        destructiveActions   = $false
        durationSeconds      = [math]::Round(($scanEnd - $scanStart).TotalSeconds, 1)
        psVersion            = $PSVersionTable.PSVersion.ToString()
        parallel             = [bool]$script:supportsParallel
        cache                = [PSCustomObject]@{
            enabled    = -not $NoCache
            ttlMinutes = $CacheTtlMinutes
            hits       = $script:cacheHits
            misses     = $script:cacheMisses
            entries    = $script:newCache.Count
        }
    }
    volumes         = $volumes
    systemFiles     = $systemFiles
    knownPaths      = $knownPaths | Sort-Object bytes -Descending
    breakdowns      = [PSCustomObject]@{
        cRoot          = $rootBreakdown
        appDataLocal   = $localBreakdown
        appDataRoaming = $roamingBreakdown
        wslFiles       = $wslFiles
    }
    largeFiles      = $largeFiles
    docker          = $docker
    recommendations = $recommendations
    errors          = $script:scanErrors.ToArray()
}

$historySnapshot = [PSCustomObject]@{
    generatedAt = $report.generatedAt
    volumes     = $volumes | ForEach-Object {
        [PSCustomObject]@{
            driveLetter = $_.driveLetter
            usedGb      = $_.usedGb
            freeGb      = $_.freeGb
            totalGb     = $_.totalGb
            usedPercent = $_.usedPercent
            health      = $_.health
        }
    }
    knownTop    = ($report.knownPaths | Select-Object -First 5 | ForEach-Object {
        [PSCustomObject]@{ label = $_.label; gb = $_.gb }
    })
}

$historyFile = Join-Path $outputDirectory "storage-history.json"
$history = Update-History -HistoryFile $historyFile -Snapshot $historySnapshot
$report | Add-Member -NotePropertyName history -NotePropertyValue $history -Force

Save-Cache

$json = $report | ConvertTo-Json -Depth 10
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedOutput, $json, $utf8NoBom)

$sourceDashboard = Join-Path $PSScriptRoot "index.html"
if (Test-Path -LiteralPath $sourceDashboard) {
    $dashboardOutput = Join-Path $outputDirectory "index.html"
    $dashboardHtml = [System.IO.File]::ReadAllText($sourceDashboard)
    $embeddedJson = $json.Replace('<', '<')
    $dashboardHtml = $dashboardHtml -replace '(?s)<script id="embeddedReportData" type="application/json">.*?</script>', "<script id=""embeddedReportData"" type=""application/json"">$embeddedJson</script>"
    [System.IO.File]::WriteAllText($dashboardOutput, $dashboardHtml, $utf8NoBom)
}

Write-Host ""
Write-Host "Storage report written to $resolvedOutput"
Write-Host "Scan duration: $($report.scan.durationSeconds)s   parallel=$($report.scan.parallel)   cache hits=$($script:cacheHits) misses=$($script:cacheMisses)   errors=$($script:scanErrors.Count)"
Write-Host "Open report dashboard at $(Join-Path $outputDirectory 'index.html')"
