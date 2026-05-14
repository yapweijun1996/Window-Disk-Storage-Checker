# Window Disk Storage Checker

A small local Windows storage report tool.

It collects disk usage data with PowerShell and renders a readable report in `index.html`. It is intentionally simple:

- no install step
- no npm packages
- no server required
- no automatic deletion
- no admin requirement for the default scan
- interactive tables use Tabulator from CDN when internet access is available

## Demo

The public demo deploys an anonymized sample report through GitHub Pages:

```text
https://yapweijun1996.github.io/Window-Disk-Storage-Checker/
```

The deployed demo uses generated sample data only. Local scans still write private report output to the ignored `Report/` folder.

## Files

- `collect-storage.ps1` - collects disk, known folder, cache, WSL, Docker, and large-file data
- `cleanup-storage.ps1` - interactive cleanups (Docker, VS Code, Temp, Recycle Bin, Claude VM); see [CLEANUP.md](CLEANUP.md)
- `compact-wsl.cmd` - administrator-only helper that compacts WSL / Docker VHDX files back to C:
- `index.html` - static dashboard template for end users and software engineers
- `CLEANUP.md` - cleanup runbook with the proven WSL TRIM + compact workflow
- `Report/` - generated dashboard copy, report data, history, and scan cache; ignored by Git

## Usage

Open PowerShell in this folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\collect-storage.ps1
```

Then open:

```text
Report\index.html
```

If the browser blocks local JSON loading, use the `Load JSON` button in the page and select `Report\storage-report.json`.

For a slower scan that also searches for files larger than 1 GB under the current user profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\collect-storage.ps1 -DeepScan
```

`-DeepScan` also enables slower full-profile and `C:\` root breakdowns. The default scan is optimized for quick MVP usage.

You can tune output size:

```powershell
powershell -ExecutionPolicy Bypass -File .\collect-storage.ps1 -Top 30 -LargeFileThresholdGB 2 -DeepScan
```

## Performance & Output Options

| Flag | Default | What it does |
|---|---|---|
| `-NoCache` | off | Bypass the persistent size cache in `Report\scan-cache.json`. |
| `-CacheTtlMinutes <n>` | `360` | Reuse cached directory sizes up to N minutes old, if their top-level mtime is unchanged. |
| `-NoProgress` | off | Hide the `Write-Progress` bar (useful in CI / non-interactive shells). |
| `-NoHistory` | off | Do not append to `Report\storage-history.json`. |
| `-HistoryRetention <n>` | `30` | Keep the last N history snapshots for the dashboard trend chart. |
| `-NoParallel` | off | Disable parallel directory sizing even on PowerShell 7+. |
| `-ParallelThrottle <n>` | `4` | Max concurrent runspaces when parallel sizing is available. |

On PowerShell 7+, top-level known paths are sized in parallel. On Windows PowerShell 5.1, the script runs sequentially with a progress bar. The first run populates the cache; subsequent runs are typically 50× faster.

## Output Files

| File | Purpose |
|---|---|
| `Report\storage-report.json` | The current report. Loaded by the dashboard. |
| `Report\storage-history.json` | Rolling array of past snapshots used to draw the C: usage sparkline. |
| `Report\scan-cache.json` | Persistent directory-size cache keyed by path + mtime. |
| `Report\index.html` | Dashboard with report data inlined (works offline, no `fetch` needed). |

## Dashboard Features

- Schema version check — warns when an older JSON is loaded against the current dashboard
- Auto-scaled size formatting (KB / MB / GB / TB)
- Recent C: usage sparkline drawn from `storage-history.json`
- Scan errors panel — surfaces paths that were skipped due to permission denied or other issues
- Docker reclaimable summary, parsed from `docker system df`
- Cache hits / misses, scan duration, and parallel mode shown in Report Metadata
- English / 中文 toggle (top right; preference saved in `localStorage`)

## Cleanup Workflow

When the dashboard shows C: in the warning / critical range:

```powershell
# 1. Refresh the report
powershell -ExecutionPolicy Bypass -File .\collect-storage.ps1

# 2. Preview what would be freed
powershell -ExecutionPolicy Bypass -File .\cleanup-storage.ps1 -All -DryRun

# 3. Run low-risk cleanups (Docker prune, VS Code caches, Temp, Recycle Bin)
powershell -ExecutionPolicy Bypass -File .\cleanup-storage.ps1 -Low

# 4. (optional) WSL/Docker VHDX compact
#    Inside each WSL distro: sudo fstrim -v /
#    Then right-click compact-wsl.cmd and choose "Run as administrator"

# 5. Re-scan to update history
powershell -ExecutionPolicy Bypass -File .\collect-storage.ps1
```

See [CLEANUP.md](CLEANUP.md) for the full runbook, individual action descriptions,
and the WSL TRIM + compact procedure.

## Safety Model

The collector only reads file sizes and writes files under `Report/`. It does not delete, move, compact, or modify system files.

Cleanup recommendations are shown as manual actions so the user can review risk first.
