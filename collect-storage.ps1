param(
    [string]$OutputPath = ".\Report\storage-report.json",
    [int]$Top = 20,
    [int64]$LargeFileThresholdGB = 1,
    [switch]$DeepScan
)

$ErrorActionPreference = "SilentlyContinue"

function ConvertTo-Gb {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes) { return 0 }
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    $measure = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum

    if ($null -eq $measure.Sum) { return 0 }
    return [int64]$measure.Sum
}

function Get-ChildBreakdown {
    param(
        [string]$Path,
        [int]$Limit = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $size = if ($_.PSIsContainer) {
                Get-DirectorySize -Path $_.FullName
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

function Get-KnownPath {
    param(
        [string]$Label,
        [string]$Path,
        [string]$Category,
        [string]$CleaningNotes,
        [bool]$UsuallySafeToClean
    )

    $bytes = Get-DirectorySize -Path $Path
    [PSCustomObject]@{
        label              = $Label
        path               = $Path
        category           = $Category
        bytes              = $bytes
        gb                 = ConvertTo-Gb $bytes
        usuallySafeToClean = $UsuallySafeToClean
        cleaningNotes      = $CleaningNotes
    }
}

$computer = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$volumes = Get-Volume |
    Where-Object { $_.DriveLetter } |
    Sort-Object DriveLetter |
    ForEach-Object {
        $used = $_.Size - $_.SizeRemaining
        $usedPercent = if ($_.Size -gt 0) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }

        [PSCustomObject]@{
            driveLetter   = "$($_.DriveLetter):"
            label         = $_.FileSystemLabel
            fileSystem    = $_.FileSystem
            totalBytes    = [int64]$_.Size
            usedBytes     = [int64]$used
            freeBytes     = [int64]$_.SizeRemaining
            totalGb       = ConvertTo-Gb $_.Size
            usedGb        = ConvertTo-Gb $used
            freeGb        = ConvertTo-Gb $_.SizeRemaining
            usedPercent   = $usedPercent
            health        = Get-DriveRisk $usedPercent
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

$profile = $env:USERPROFILE
$knownPathRequests = @(
    Get-KnownPath "AppData Local" "$profile\AppData\Local" "app-data" "Application caches, VM files, browser data, and local app storage." $false
    Get-KnownPath "AppData Roaming" "$profile\AppData\Roaming" "app-data" "Application profiles and synced settings. Clean app-specific caches only." $false
    Get-KnownPath "Downloads" "$profile\Downloads" "user-files" "Usually safe to review, archive, or move to another drive." $true
    Get-KnownPath "Documents" "$profile\Documents" "user-files" "Review manually; move large archives/projects to a data drive." $false
    Get-KnownPath "Desktop" "$profile\Desktop" "user-files" "Review manually; often contains temporary work files." $false
    Get-KnownPath "Pictures" "$profile\Pictures" "user-files" "Move media libraries to a data drive if large." $false
    Get-KnownPath "Videos" "$profile\Videos" "user-files" "Move media libraries to a data drive if large." $false
    Get-KnownPath "Temp" "$profile\AppData\Local\Temp" "cache" "Usually safe to clean after closing applications." $true
    Get-KnownPath "Chrome" "$profile\AppData\Local\Google\Chrome" "browser" "Use Chrome clear browsing data; do not delete the whole profile blindly." $false
    Get-KnownPath "Docker Desktop" "$profile\AppData\Local\Docker" "developer" "Use docker builder prune/system prune instead of deleting vhdx files manually." $false
    Get-KnownPath "WSL local disk" "$profile\AppData\Local\wsl" "developer" "Clean Linux distro contents first, then compact the VHDX." $false
    Get-KnownPath "VS Code roaming data" "$profile\AppData\Roaming\Code" "developer" "CachedExtensionVSIXs, Cache, and CachedData are common cleanup targets." $false
    Get-KnownPath "Windows recycle bin" "C:\`$Recycle.Bin" "cleanup" "Usually safe to empty after reviewing deleted files." $true
)

if ($DeepScan) {
    $knownPaths = @(
        Get-KnownPath "User profile" $profile "profile" "Largest user-owned area. Drill down before deleting anything." $false
    ) + $knownPathRequests
} else {
    $knownPaths = $knownPathRequests
}

$rootBreakdown = if ($DeepScan) { Get-ChildBreakdown -Path "C:\" -Limit $Top } else { @() }
$localBreakdown = Get-ChildBreakdown -Path "$profile\AppData\Local" -Limit $Top
$roamingBreakdown = Get-ChildBreakdown -Path "$profile\AppData\Roaming" -Limit $Top
$wslFiles = Get-ChildItem -LiteralPath "$profile\AppData\Local\wsl" -Force -Recurse -File -ErrorAction SilentlyContinue |
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
    $largeFiles = Get-ChildItem -LiteralPath $profile -Force -Recurse -File -ErrorAction SilentlyContinue |
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
}

$docker = $null
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerText = docker system df 2>$null
    $docker = [PSCustomObject]@{
        available = $true
        summary   = $dockerText
        notes     = "Run docker builder prune to remove unused build cache."
    }
} else {
    $docker = [PSCustomObject]@{
        available = $false
        summary   = @()
        notes     = "Docker CLI was not found in PATH."
    }
}

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

$report = [PSCustomObject]@{
    schemaVersion   = "1.0"
    generatedAt     = (Get-Date).ToString("o")
    host            = [PSCustomObject]@{
        computerName = $env:COMPUTERNAME
        userName     = $env:USERNAME
        osCaption    = $os.Caption
        osVersion    = $os.Version
        architecture = $os.OSArchitecture
        manufacturer = $computer.Manufacturer
        model        = $computer.Model
    }
    scan            = [PSCustomObject]@{
        top                 = $Top
        deepScan            = [bool]$DeepScan
        largeFileThresholdGb = $LargeFileThresholdGB
        adminRequired       = $false
        destructiveActions  = $false
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
}

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

$json = $report | ConvertTo-Json -Depth 8
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedOutput, $json, $utf8NoBom)

$sourceDashboard = Join-Path $PSScriptRoot "index.html"
if (Test-Path -LiteralPath $sourceDashboard) {
    $dashboardOutput = Join-Path $outputDirectory "index.html"
    $dashboardHtml = [System.IO.File]::ReadAllText($sourceDashboard)
    $embeddedJson = $json.Replace("<", "\u003c")
    $dashboardHtml = $dashboardHtml -replace '(?s)<script id="embeddedReportData" type="application/json">.*?</script>', "<script id=""embeddedReportData"" type=""application/json"">$embeddedJson</script>"
    [System.IO.File]::WriteAllText($dashboardOutput, $dashboardHtml, $utf8NoBom)
}

Write-Host "Storage report written to $resolvedOutput"
Write-Host "Open report dashboard at $(Join-Path $outputDirectory "index.html")"
