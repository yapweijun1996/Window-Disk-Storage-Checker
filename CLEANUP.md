# Cleanup Runbook

A reusable playbook for freeing space on a Windows 10/11 dev machine when
`collect-storage.ps1` shows C: in the warning or critical range.

The two entry points are:

| Tool | What it does | Privilege |
|---|---|---|
| [`cleanup-storage.ps1`](cleanup-storage.ps1) | Interactive cleanups: Docker, VS Code caches, Temp, Recycle Bin, Claude VM bundle | User |
| [`compact-wsl.cmd`](compact-wsl.cmd) | Reclaims unused blocks inside WSL / Docker VHDX files back to C: | Administrator |

Both are **non-destructive by default** — every deletion prompts for confirmation
unless you pass `-Yes`. The collector itself never deletes anything.

## Recommended workflow

```text
1. Scan       →  .\collect-storage.ps1          (refresh report)
2. Plan       →  open Report\index.html         (see Known Areas + recommendations)
3. Clean      →  .\cleanup-storage.ps1 -Low     (low-risk batch)
4. Compact    →  right-click compact-wsl.cmd → Run as administrator
5. Verify     →  .\collect-storage.ps1          (compare with history sparkline)
```

## cleanup-storage.ps1

### Show available actions

```powershell
.\cleanup-storage.ps1
# or
.\cleanup-storage.ps1 -List
```

### Run low-risk actions only

```powershell
.\cleanup-storage.ps1 -Low
```

This runs, with confirmation prompts: `recycle-bin`, `docker`, `vscode-cache`,
`temp`.

### Run everything

```powershell
.\cleanup-storage.ps1 -All
```

Adds `claude-vm` (medium risk) and prints the `wsl-compact` hand-off.

### Run specific actions

```powershell
.\cleanup-storage.ps1 docker vscode-cache temp
```

### Preview (no deletion)

```powershell
.\cleanup-storage.ps1 -All -DryRun
```

### Skip confirmation prompts

```powershell
.\cleanup-storage.ps1 -Low -Yes
```

### Tune Temp age threshold

```powershell
.\cleanup-storage.ps1 temp -TempDays 14
```

## Actions in detail

### recycle-bin (low)

Calls `Clear-RecycleBin -Force`. Skipped if already empty.

### docker (low)

Runs `docker system df` for visibility, then `docker builder prune -f`.
Removes unused image build cache only — running containers / images are kept.
The freed bytes live inside the Docker VHDX; run `compact-wsl.cmd` to actually
shrink C:.

### vscode-cache (low)

Deletes contents of these folders under `%APPDATA%\Code`:

- `Cache`
- `CachedData`
- `CachedExtensionVSIXs`
- `Code Cache`
- `GPUCache`

VS Code will rebuild what it needs on next launch. Extensions are NOT touched
(they live in `%USERPROFILE%\.vscode\extensions`).

### temp (low)

Deletes files in `%LOCALAPPDATA%\Temp` older than `-TempDays` (default 7).
Locked files are skipped silently.

### claude-vm (medium)

Deletes `%APPDATA%\Claude\vm_bundles\claudevm.bundle` (the Claude Cowork VM
image, typically 10–15 GB). Cowork is rebuilt on next use, so this is reversible
at the cost of a one-time rebuild.

### wsl-compact (info)

Prints a hand-off — the actual compact needs admin and runs from
`compact-wsl.cmd` (see below).

### report (low)

Re-runs `collect-storage.ps1` so the dashboard reflects the new state.

## compact-wsl.cmd

Reclaiming WSL space is a **two-step** process. Diskpart's `compact vdisk` only
returns blocks that are zeroed at the block-device level — ext4 marks free
blocks in its bitmap but does not zero them. You must TRIM the filesystem first.

### Step 1 — TRIM inside each Linux distro

Open WSL and run:

```bash
sudo apt-get clean
sudo journalctl --vacuum-time=3d
sudo fstrim -v /
exit
```

Expect output like `/: 5 GiB (5400000000 bytes) trimmed`. The actual figure is
the upper bound of what compact can reclaim.

(Skip the `apt-get` / `journalctl` lines if the distro is not Debian/Ubuntu.)

### Step 2 — Compact the VHDX from Windows

Right-click `compact-wsl.cmd` → **Run as administrator**.

The script will:

1. Verify it is elevated (exits cleanly if not).
2. Auto-discover all `*.vhdx` files under `%LOCALAPPDATA%\wsl`,
   `%LOCALAPPDATA%\Packages`, and `%LOCALAPPDATA%\Docker\wsl`.
3. Print pre-compact byte sizes.
4. Kill Docker Desktop processes (`Docker Desktop.exe`, `com.docker.*`,
   `vpnkit.exe`).
5. `wsl --shutdown`.
6. Stop services that hold VHDX handles: `com.docker.service`, `LxssManager`,
   `vmcompute` (the Hyper-V Host Compute Service — this is the one that
   actually has the file open).
7. Wait up to 15s for `vmcompute` to report `STOPPED`.
8. Run `diskpart compact vdisk` against each discovered VHDX in read-only mode.
9. Print post-compact byte sizes.
10. Start `vmcompute` again (WSL and Docker re-attach on demand).

### If diskpart says "file is in use"

Some other process is holding the VHDX. The cleanest fix:

1. Save your work.
2. Reboot Windows.
3. Run `compact-wsl.cmd` **immediately**, before opening Docker Desktop, VS
   Code's Remote-WSL, or any WSL terminal.

### Expected gains

After a proper `fstrim` + compact:

- A 32 GB Ubuntu VHDX that contains 27 GB of real files compacts to ~26–28 GB.
- A Docker VHDX that just had `builder prune` releases its 2–3 GB.

Without `fstrim`, compact typically reclaims only a few hundred MB.

## Things this project never does

- Touch `pagefile.sys`, `swapfile.sys`, registry, page file size, or System
  Restore points.
- Delete browser profiles (only Chrome's `Cache` cleanup is suggested via UI —
  not scripted, because logout / autofill / cookies are easy to lose).
- Touch user files under `Documents`, `Desktop`, `Pictures`, `Videos`.
- Bypass UAC or auto-elevate.

If you want any of these, do it through Windows Settings → Storage so the
system handles the side effects.
