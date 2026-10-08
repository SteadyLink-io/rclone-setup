# Set up rclone for SteadyLink on Windows.
#
#   irm https://steadylink.io/install/rclone.ps1 | iex
#
# Pass an app key to skip the prompts:
#
#   $env:STEADYLINK_ACCESS_KEY_ID='SL...'; $env:STEADYLINK_SECRET_ACCESS_KEY='...'; irm https://steadylink.io/install/rclone.ps1 | iex
#
# Switches need the script block form, for example:
#
#   & ([scriptblock]::Create((irm https://steadylink.io/install/rclone.ps1))) -Uninstall
#
# Works in Windows PowerShell 5.1 and PowerShell 7.
# Source and documentation: https://github.com/SteadyLink-io/rclone-setup
# steadylink.io serves a copy of this file. Make changes in that repository.

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NonInteractive,
    [string]$Remote,
    [switch]$Help
)

& {
    param([bool]$Uninstall, [bool]$NonInteractive, [string]$Remote, [bool]$Help)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $RepoUrl = 'https://github.com/SteadyLink-io/rclone-setup'
    $MinVersion = [version]'1.65'
    $Endpoint = if ($env:STEADYLINK_ENDPOINT) { $env:STEADYLINK_ENDPOINT } else { 'https://api.steadylink.io/s3' }
    if (-not $Remote) { $Remote = if ($env:STEADYLINK_REMOTE) { $env:STEADYLINK_REMOTE } else { 'steadylink' } }
    if ($env:STEADYLINK_NONINTERACTIVE -eq '1') { $NonInteractive = $true }
    if ($env:STEADYLINK_UNINSTALL -eq '1') { $Uninstall = $true }
    $DataDir = Join-Path $env:LOCALAPPDATA 'SteadyLink'
    $LogDir = Join-Path $DataDir 'logs'
    $JobDir = Join-Path $DataDir 'jobs'
    $TaskPrefix = 'SteadyLink '

    # Shared mutable state for the nested functions below.
    $S = @{ Rclone = $null; ConfigFile = $null; Encrypted = $false; KeyId = ''; Secret = ''; Buckets = @() }

    if ($NonInteractive -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        $Interactive = $false
    } else {
        $Interactive = $true
    }

    # ------------------------------------------------------------------
    # Output and prompts

    function Say([string]$Text = '') { Write-Host $Text }
    function Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor White }
    function Ok([string]$Text) { Write-Host 'ok ' -ForegroundColor Green -NoNewline; Write-Host $Text }
    function Note([string]$Text) { Write-Host $Text -ForegroundColor DarkGray }
    function Warn([string]$Text) { Write-Host 'warning: ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
    function Fail([string]$Text) { throw [System.InvalidOperationException]::new($Text) }

    function Ask([string]$Question, [string]$Default = '') {
        $prompt = if ($Default) { "$Question [$Default]" } else { $Question }
        $answer = Read-Host -Prompt $prompt
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }

    function AskSecret([string]$Question) {
        $secure = Read-Host -Prompt $Question -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }

    function Confirm([string]$Question, [bool]$Default = $false) {
        if (-not $Interactive) { return $Default }
        $hint = if ($Default) { 'Y/n' } else { 'y/N' }
        while ($true) {
            $answer = Read-Host -Prompt "$Question [$hint]"
            if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
            switch -Regex ($answer.Trim()) {
                '^(y|yes)$' { return $true }
                '^(n|no)$' { return $false }
            }
        }
    }

    function Redact([string]$Text) {
        if ($S.Secret) { return $Text.Replace($S.Secret, '****') }
        return $Text
    }

    # Quote one argument for a Windows command line (CommandLineToArgvW rules).
    function ConvertTo-Argument([string]$Value) {
        if ($Value -and $Value -notmatch '[\s"]') { return $Value }
        $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }

    function ConvertTo-PSLiteral([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }

    function ConvertTo-Slug([string]$Value) {
        $slug = ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ($slug) { return $slug }
        return 'folder'
    }

    # ------------------------------------------------------------------
    # rclone

    # Runs rclone and returns exit code and combined output. Windows PowerShell
    # turns native stderr into errors, so errors are relaxed for the call.
    function Invoke-Rclone([string[]]$Arguments) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $S.Rclone @Arguments 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        return [pscustomobject]@{ ExitCode = $code; Output = (@($output) -join "`n") }
    }

    function Sync-SessionPath {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
    }

    function Find-Rclone {
        $cmd = Get-Command rclone.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\rclone.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\rclone\rclone.exe')
        )
        $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path $wingetPackages) {
            $candidates += Get-ChildItem -Path $wingetPackages -Filter 'rclone.exe' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName }
        }
        foreach ($path in $candidates) { if ($path -and (Test-Path $path)) { return $path } }
        return $null
    }

    function Get-RcloneVersion {
        $result = Invoke-Rclone @('version')
        if ($result.Output -match 'rclone v?(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
        return $null
    }

    function Install-RcloneZip {
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'ARM64' { 'arm64' }
            'x86' { if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { 'amd64' } else { '386' } }
            default { 'amd64' }
        }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('steadylink-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $versionText = (Invoke-WebRequest -UseBasicParsing -Uri 'https://downloads.rclone.org/version.txt').Content
            if ($versionText -is [byte[]]) { $versionText = [Text.Encoding]::ASCII.GetString($versionText) }
            if ($versionText -notmatch 'rclone (v\d+\.\d+\.\d+)') { Fail 'could not read the current rclone version from downloads.rclone.org' }
            $version = $Matches[1]
            $zipName = "rclone-$version-windows-$arch.zip"
            $zip = Join-Path $tmp $zipName
            Say "Downloading $zipName"
            Invoke-WebRequest -UseBasicParsing -Uri "https://downloads.rclone.org/$version/$zipName" -OutFile $zip
            $sums = Join-Path $tmp 'SHA256SUMS'
            Invoke-WebRequest -UseBasicParsing -Uri "https://downloads.rclone.org/$version/SHA256SUMS" -OutFile $sums
            $line = Get-Content $sums | Where-Object { $_ -match ('^([0-9a-f]{64})\s+' + [regex]::Escape($zipName) + '$') } | Select-Object -First 1
            if (-not $line) { Fail "$zipName is not listed in SHA256SUMS; not installing it" }
            $expected = ($line -split '\s+')[0]
            $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
            if ($expected -ne $actual) { Fail "checksum mismatch for $zipName; not installing it" }
            Ok 'checksum matches SHA256SUMS'
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $target = Join-Path $env:LOCALAPPDATA 'Programs\rclone'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $tmp "rclone-$version-windows-$arch\rclone.exe") -Destination $target -Force
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $parts = @($userPath -split ';' | Where-Object { $_ })
            if ($parts -notcontains $target) {
                [Environment]::SetEnvironmentVariable('Path', (($parts + $target) -join ';'), 'User')
                Note "Added $target to your user PATH."
            }
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Install-RcloneWinget([bool]$Upgrade) {
        $verb = if ($Upgrade) { 'upgrade' } else { 'install' }
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & winget $verb --id Rclone.Rclone --exact --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Host
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        return ($code -eq 0)
    }

    function Install-Rclone {
        Step 'Checking rclone'
        $S.Rclone = Find-Rclone
        $current = $null
        if ($S.Rclone) {
            $current = Get-RcloneVersion
            if ($current -and $current -ge $MinVersion) {
                Ok "rclone $current at $($S.Rclone)"
                return
            }
            $shown = if ($current) { $current } else { 'of unknown version' }
            Say "rclone $shown is installed at $($S.Rclone), but $MinVersion or newer is needed."
        } else {
            Say 'rclone is not installed.'
        }

        if ($Interactive -and -not (Confirm 'Install the current rclone release?' $true)) {
            Fail "rclone $MinVersion or newer is required."
        }

        $hasWinget = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
        $fromWinget = $S.Rclone -and ($S.Rclone -like '*\WinGet\*')
        $installed = $false
        if ($hasWinget -and ($fromWinget -or -not $S.Rclone)) {
            Say 'Installing rclone with winget.'
            $installed = Install-RcloneWinget $fromWinget
            if (-not $installed) { Warn 'winget did not finish. Falling back to the zip from downloads.rclone.org.' }
        }
        if (-not $installed) { Install-RcloneZip }

        Sync-SessionPath
        $S.Rclone = Find-Rclone
        if (-not $S.Rclone) { Fail 'rclone was installed but cannot be found. Open a new PowerShell window and run this again.' }
        $current = Get-RcloneVersion
        if (-not $current -or $current -lt $MinVersion) {
            Fail "rclone at $($S.Rclone) is still older than $MinVersion. Remove it and run this again."
        }
        Ok "rclone $current at $($S.Rclone)"
    }

    function Read-RcloneConfig {
        $S.ConfigFile = ((Invoke-Rclone @('config', 'file')).Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
        $S.Encrypted = $false
        if ((Test-Path $S.ConfigFile) -and ((Get-Content -Path $S.ConfigFile -TotalCount 1) -like '# Encrypted rclone configuration*')) {
            $S.Encrypted = $true
            if (-not $env:RCLONE_CONFIG_PASS) {
                if (-not $Interactive) { Fail 'your rclone config is encrypted. Set RCLONE_CONFIG_PASS and run this again.' }
                $env:RCLONE_CONFIG_PASS = AskSecret 'rclone config password'
                $S.SetConfigPass = $true
            }
            if ((Invoke-Rclone @('listremotes')).ExitCode -ne 0) { Fail 'could not open the rclone config. Check the password.' }
        }
    }

    function Get-RemoteType {
        $list = Invoke-Rclone @('listremotes', '--long')
        foreach ($line in ($list.Output -split "`n")) {
            $fields = $line.Trim() -split '\s+'
            if ($fields.Count -ge 2 -and $fields[0] -eq "${Remote}:") { return $fields[1] }
        }
        return $null
    }

    # ------------------------------------------------------------------
    # Remote

    function Read-AppKey {
        $S.KeyId = ([string]$env:STEADYLINK_ACCESS_KEY_ID) -replace '\s', ''
        $S.Secret = ([string]$env:STEADYLINK_SECRET_ACCESS_KEY) -replace '\s', ''
        if (-not $S.KeyId -or -not $S.Secret) {
            if (-not $Interactive) { Fail 'no app key. Set STEADYLINK_ACCESS_KEY_ID and STEADYLINK_SECRET_ACCESS_KEY, or run this in a PowerShell window.' }
            Say 'You need a SteadyLink app key. The secret is shown only once, when the key is created.'
        }
        while (-not $S.KeyId) { $S.KeyId = (Ask 'Access key ID') -replace '\s', '' }
        if (-not $S.KeyId.StartsWith('SL')) { Warn "SteadyLink access key IDs start with SL. '$($S.KeyId)' may not be a SteadyLink app key." }
        while (-not $S.Secret) { $S.Secret = (AskSecret 'Secret access key (input hidden)') -replace '\s', '' }
    }

    function Save-SteadyLinkRemote {
        Step "Configuring the rclone remote '$Remote'"
        Read-RcloneConfig
        $existing = Get-RemoteType
        $verb = 'create'
        if ($existing) {
            if ($Interactive) {
                if (-not (Confirm "A remote called '$Remote' already exists. Replace its settings with this key?" $false)) {
                    Fail "left '$Remote' unchanged. Run again with `$env:STEADYLINK_REMOTE='another-name' to add a second remote."
                }
            } else {
                Say "Updating the existing remote '$Remote'."
            }
            if ($existing -eq 's3') { $verb = 'update' }
            else { Invoke-Rclone @('config', 'delete', $Remote) | Out-Null }
        }

        # rclone prints the whole remote, secret included, after create and
        # update, so the output stays out of the console.
        $arguments = if ($verb -eq 'create') { @('config', 'create', $Remote, 's3') } else { @('config', 'update', $Remote) }
        $arguments += @(
            'provider=Other',
            'env_auth=false',
            "access_key_id=$($S.KeyId)",
            "secret_access_key=$($S.Secret)",
            "endpoint=$Endpoint",
            'region=auto',
            'force_path_style=true',
            '--non-interactive'
        )
        $result = Invoke-Rclone $arguments
        if ($result.ExitCode -ne 0) {
            Write-Host (Redact $result.Output)
            Fail 'rclone could not save the remote.'
        }
        Ok "saved '$Remote' in $($S.ConfigFile)"
        if (-not $S.Encrypted) {
            Note 'The secret is stored in that file, under your user profile. To encrypt the file, run: rclone config encryption set'
        }
    }

    function Write-ErrorHelp([string]$Output) {
        if ($Output -match 'SignatureDoesNotMatch') {
            Say 'SteadyLink recognised the access key ID, but the secret does not match it.'
            Say 'Copy the secret again, without spaces or line breaks. If you no longer have it, create a new app key.'
        } elseif ($Output -match 'InvalidAccessKeyId') {
            Say 'SteadyLink does not know this access key ID. It may be mistyped or the key may have been revoked.'
            Say 'Check that it starts with SL, or create a new app key.'
        } elseif ($Output -match 'RequestTimeTooSkewed') {
            Say "Your computer's clock is too far off for the request to be accepted. Turn on 'Set time automatically' and try again."
        } elseif ($Output -match 'QuotaExceeded') {
            Say 'The key works, but the workspace has used its storage allowance.'
        } elseif ($Output -match 'SlowDown') {
            Say "SteadyLink is rate limiting this key. Wait a minute and run the check again: rclone lsd ${Remote}:"
        } elseif ($Output -match 'AccessDenied') {
            Say 'The key was rejected. Usually it has been revoked, or its owner was removed from the workspace'
            Say 'or no longer has access. Create a new app key, or ask a workspace admin to check your role.'
        } elseif ($Output -match 'no such host|dial tcp|connection refused|actively refused|timeout') {
            Say "Could not reach $Endpoint. Check your internet connection, proxy or firewall."
        } elseif ($Output -match 'x509|certificate') {
            Say "The TLS certificate for $Endpoint could not be verified. A proxy or antivirus that inspects HTTPS"
            Say 'traffic is the usual cause. Your clock may also be wrong.'
        } else {
            Say 'rclone could not list buckets. Its last message is above.'
        }
    }

    function Test-SteadyLinkRemote {
        Step 'Checking the connection'
        $result = Invoke-Rclone @('lsd', "${Remote}:", '--retries', '1', '--low-level-retries', '2', '--contimeout', '15s', '--timeout', '60s')
        if ($result.ExitCode -eq 0) {
            $S.Buckets = @($result.Output -split "`n" | ForEach-Object { $f = $_.Trim() -split '\s+'; if ($f.Count -ge 5) { $f[-1] } })
            if ($S.Buckets.Count -gt 0) {
                Ok 'connected. Buckets this key can see:'
                $S.Buckets | ForEach-Object { Say "    $_" }
            } else {
                Ok 'connected. This key cannot see any buckets yet.'
                Note "Create one in the dashboard, or with: rclone mkdir ${Remote}:my-bucket"
            }
            return $true
        }
        $lines = @((Redact $result.Output) -split "`n" | Where-Object { $_ -match 'error' } | Select-Object -Last 3)
        $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Say ''
        Write-ErrorHelp $result.Output
        Say ''
        Say 'The remote was saved. Run this script again with the right key to replace it.'
        return $false
    }

    # ------------------------------------------------------------------
    # Scheduled tasks

    function Register-SteadyLinkTask([string]$Name, $Action, $Trigger, [TimeSpan]$TimeLimit) {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit $TimeLimit
        $task = New-ScheduledTask -Action $Action -Trigger $Trigger -Principal $principal -Settings $settings `
            -Description "Created by $RepoUrl"
        Register-ScheduledTask -TaskName "$TaskPrefix$Name" -InputObject $task -Force | Out-Null
    }

    function Write-EncryptedConfigWarning {
        if ($S.Encrypted) {
            Warn 'your rclone config is encrypted, so this task cannot read it without a password.'
            Warn 'Add --password-command to the task, or keep a separate unencrypted config for it.'
        }
    }

    # ------------------------------------------------------------------
    # Mount

    function Test-WinFsp {
        foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\WinFsp', 'HKLM:\SOFTWARE\WinFsp') {
            $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($item -and ($item.PSObject.Properties.Name -contains 'InstallDir') -and (Test-Path $item.InstallDir)) { return $true }
        }
        return (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'WinFsp\bin'))
    }

    function Get-FreeDriveLetter([string]$Preferred) {
        $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $order = @($Preferred) + @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'R', 'Q', 'P', 'O', 'N', 'M')
        foreach ($letter in $order) { if ($letter -and $used -notcontains $letter) { return $letter } }
        return $null
    }

    function Add-SteadyLinkMount {
        Step 'Mount SteadyLink as a drive'
        Say 'This shows your buckets as folders on a drive letter and mounts it each time you sign in.'
        if (-not (Confirm 'Set up the drive?' $false)) { return }

        if (-not (Test-WinFsp)) {
            Say 'rclone needs WinFsp (https://winfsp.dev) to mount drives on Windows.'
            if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                Warn 'winget is not available. Install WinFsp from https://winfsp.dev/rel/ and run this script again.'
                return
            }
            if (-not (Confirm 'Install WinFsp with winget? Windows will ask for permission.' $true)) { return }
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & winget install --id WinFsp.WinFsp --exact --source winget --accept-source-agreements --accept-package-agreements | Out-Host }
            finally { $ErrorActionPreference = $previous }
            if (-not (Test-WinFsp)) {
                Warn 'WinFsp does not look installed. Install it from https://winfsp.dev/rel/ and run this script again.'
                return
            }
        }

        $default = Get-FreeDriveLetter 'S'
        if (-not $default) { Warn 'no free drive letter.'; return }
        while ($true) {
            $letter = (Ask 'Drive letter' $default).TrimEnd(':', '\').ToUpperInvariant()
            if ($letter -match '^[D-Z]$' -and (Get-FreeDriveLetter $letter) -eq $letter) { break }
            Warn "$letter is not a free drive letter."
        }
        Write-EncryptedConfigWarning

        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        $arguments = @('mount', "${Remote}:", "${letter}:", '--vfs-cache-mode', 'full', '--network-mode',
            '--vfs-cache-max-age', '24h', '--dir-cache-time', '5m', '--no-console',
            '--config', $S.ConfigFile, '--log-file', (Join-Path $LogDir 'mount.log'), '--log-level', 'NOTICE')
        $action = New-ScheduledTaskAction -Execute $S.Rclone -Argument (($arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        Stop-ScheduledTask -TaskName "${TaskPrefix}Mount" -ErrorAction SilentlyContinue
        Register-SteadyLinkTask -Name 'Mount' -Action $action -Trigger $trigger -TimeLimit ([TimeSpan]::Zero)
        Start-ScheduledTask -TaskName "${TaskPrefix}Mount"
        $mounted = $false
        for ($i = 0; $i -lt 15 -and -not $mounted; $i++) {
            Start-Sleep -Seconds 1
            $mounted = Test-Path "${letter}:\"
        }
        if ($mounted) { Ok "SteadyLink is on ${letter}:" }
        else { Warn "the drive has not appeared yet. Check $(Join-Path $LogDir 'mount.log')" }
        Note "Mounts at sign-in (Task Scheduler: '${TaskPrefix}Mount'). Log: $(Join-Path $LogDir 'mount.log')"
    }

    # ------------------------------------------------------------------
    # Scheduled backup

    function Add-SteadyLinkBackup {
        Step 'Scheduled backup'
        Say 'This copies a local folder to a bucket on a schedule, logging each run.'
        if (-not (Confirm 'Set up a scheduled backup?' $false)) { return }

        while ($true) {
            $source = Ask 'Folder to back up' ([Environment]::GetFolderPath('MyDocuments'))
            if (Test-Path -LiteralPath $source -PathType Container) {
                $source = (Resolve-Path -LiteralPath $source).ProviderPath
                break
            }
            Warn "$source is not a folder."
        }

        $defaultBucket = if ($S.Buckets.Count -gt 0) { $S.Buckets[0] } else { '' }
        while ($true) {
            $bucket = Ask 'Bucket' $defaultBucket
            if (-not $bucket) { continue }
            if ($S.Buckets -contains $bucket) { break }
            if (Confirm "Bucket '$bucket' was not in the list. Create it?" $false) {
                if ((Invoke-Rclone @('mkdir', "${Remote}:$bucket")).ExitCode -eq 0) { Ok "created $bucket"; break }
                Warn "could not create $bucket. Bucket names are 3 to 63 lowercase letters, digits and hyphens."
            }
        }

        $leaf = Split-Path -Path $source -Leaf
        if (-not $leaf) { $leaf = $source.Substring(0, 1) }
        $destPath = (Ask 'Folder inside the bucket' ("$(ConvertTo-Slug $env:COMPUTERNAME)/$leaf")).Trim('/')
        $dest = "${Remote}:$bucket/$destPath"

        Say ''
        Say '  copy  uploads new and changed files. Files you delete locally stay in SteadyLink.'
        Say '  sync  makes the bucket folder match the local folder. Files deleted locally are'
        Say "        moved to $bucket/.deleted/$destPath instead of being removed."
        do { $mode = (Ask 'Mode (copy or sync)' 'copy').ToLowerInvariant() } until ($mode -in 'copy', 'sync')
        do { $when = (Ask "Run daily at which hour (0-23), or 'hourly'" '2').ToLowerInvariant() } until ($when -eq 'hourly' -or ($when -match '^\d{1,2}$' -and [int]$when -le 23))

        $job = ConvertTo-Slug $leaf
        $log = Join-Path $LogDir "backup-$job.log"
        Write-EncryptedConfigWarning

        $arguments = @($mode, $source, $dest, '--config', $S.ConfigFile, '--log-file', $log, '--log-level', 'INFO', '--stats', '0',
            '--exclude', 'desktop.ini', '--exclude', 'Thumbs.db', '--exclude', '~$*')
        if ($mode -eq 'sync') { $arguments += @('--backup-dir', "${Remote}:$bucket/.deleted/$destPath") }

        # The task runs a small script so it stays readable in Task Scheduler
        # and runs without a console window.
        New-Item -ItemType Directory -Path $JobDir, $LogDir -Force | Out-Null
        $runner = Join-Path $JobDir "backup-$job.ps1"
        $lines = @(
            "# SteadyLink backup of $source to $dest",
            "# Created by $RepoUrl. Remove with the -Uninstall switch.",
            "& $(ConvertTo-PSLiteral $S.Rclone) $(($arguments | ForEach-Object { ConvertTo-PSLiteral $_ }) -join ' ')",
            'exit $LASTEXITCODE'
        )
        Set-Content -Path $runner -Value $lines -Encoding UTF8

        $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $(ConvertTo-Argument $runner)"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
        if ($when -eq 'hourly') {
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours((Get-Date).Hour + 1) -RepetitionInterval (New-TimeSpan -Hours 1)
        } else {
            $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours([int]$when))
        }
        Register-SteadyLinkTask -Name "Backup $job" -Action $action -Trigger $trigger -TimeLimit (New-TimeSpan -Hours 23)
        Ok "backup task '${TaskPrefix}Backup $job' created"
        Note "Log: $log"
        Note "Script: $runner"
        if (Confirm 'Run the first backup now, in the background?' $false) {
            Start-ScheduledTask -TaskName "${TaskPrefix}Backup $job"
            Ok "started. Follow it with: Get-Content -Wait '$log'"
        }
    }

    # ------------------------------------------------------------------
    # Uninstall

    function Uninstall-SteadyLinkSetup {
        Step 'Removing SteadyLink drive and backup tasks'
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$TaskPrefix*" -and $_.TaskPath -eq '\' })
        foreach ($task in $tasks) {
            Stop-ScheduledTask -TaskName $task.TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
            Ok "removed task '$($task.TaskName)'"
        }
        if ($tasks.Count -eq 0) { Say 'No drive or backup tasks found.' }
        if (Test-Path $JobDir) { Remove-Item -Path $JobDir -Recurse -Force; Ok "removed $JobDir" }

        $S.Rclone = Find-Rclone
        if ($S.Rclone) {
            Read-RcloneConfig
            if ((Get-RemoteType) -and (Confirm "Remove the rclone remote '$Remote' (and the key stored in it)?" $false)) {
                Invoke-Rclone @('config', 'delete', $Remote) | Out-Null
                Ok "removed remote '$Remote'"
            }
            if (Confirm 'Uninstall rclone itself?' $false) {
                if ($S.Rclone -like '*\WinGet\*') {
                    & winget uninstall --id Rclone.Rclone --exact | Out-Host
                } else {
                    $dir = Split-Path -Parent $S.Rclone
                    Remove-Item -Path $S.Rclone -Force
                    $parts = @(([Environment]::GetEnvironmentVariable('Path', 'User')) -split ';' | Where-Object { $_ -and $_ -ne $dir })
                    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
                }
                Ok "removed $($S.Rclone)"
            }
        }
        Say ''
        Say 'Files in SteadyLink and on this computer were not touched.'
        Say "Logs, if any, are in $LogDir. WinFsp, if installed, stays; remove it with: winget uninstall WinFsp.WinFsp"
    }

    # ------------------------------------------------------------------

    if ($Help) {
        Say 'Set up rclone for SteadyLink.'
        Say ''
        Say 'Switches: -Uninstall, -NonInteractive, -Remote NAME'
        Say 'Environment: STEADYLINK_ACCESS_KEY_ID, STEADYLINK_SECRET_ACCESS_KEY, STEADYLINK_ENDPOINT,'
        Say '             STEADYLINK_REMOTE, STEADYLINK_NONINTERACTIVE=1'
        Say "Docs: $RepoUrl"
        return
    }

    if ($Remote -notmatch '^[A-Za-z0-9_-]+$') {
        Write-Host "error: remote name may only contain letters, digits, - and _: '$Remote'" -ForegroundColor Red
        return
    }

    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    $S.SetConfigPass = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        if ($Uninstall) {
            Uninstall-SteadyLinkSetup
            return
        }
        Write-Host 'SteadyLink rclone setup' -ForegroundColor White
        Note "Endpoint $Endpoint, remote '$Remote'"
        Install-Rclone
        Read-AppKey
        Save-SteadyLinkRemote
        if (-not (Test-SteadyLinkRemote)) {
            $global:LASTEXITCODE = 1
            return
        }
        if ($Interactive) {
            Add-SteadyLinkMount
            Add-SteadyLinkBackup
        }
        Step 'Done'
        Say 'Try:'
        Say "    rclone lsd ${Remote}:"
        Say "    rclone copy `"$([Environment]::GetFolderPath('MyPictures'))`" ${Remote}:my-bucket/pictures --progress"
        Say ''
        Say 'Run this script again any time to change the key, drive or backups.'
        Say "Remove the tasks with: & ([scriptblock]::Create((irm https://steadylink.io/install/rclone.ps1))) -Uninstall"
        Say "Docs: $RepoUrl"
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host ''
        Write-Host "error: $(Redact $_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        if ($S.SetConfigPass) { Remove-Item Env:\RCLONE_CONFIG_PASS -ErrorAction SilentlyContinue }
        $S.Secret = ''
    }
} -Uninstall:$Uninstall -NonInteractive:$NonInteractive -Remote $Remote -Help:$Help
