# Window Disk Storage Checker

A small local Windows storage report tool.

It collects disk usage data with PowerShell and renders a readable report in `index.html`. It is intentionally simple:

- no install step
- no npm packages
- no server required
- no automatic deletion
- no admin requirement for the default scan
- interactive tables use Tabulator from CDN when internet access is available

## Files

- `collect-storage.ps1` - collects disk, known folder, cache, WSL, Docker, and large-file data
- `index.html` - static dashboard template for end users and software engineers
- `Report/` - generated dashboard copy and report data; ignored by Git

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

## Safety Model

The collector only reads file sizes and writes files under `Report/`. It does not delete, move, compact, or modify system files.

Cleanup recommendations are shown as manual actions so the user can review risk first.
