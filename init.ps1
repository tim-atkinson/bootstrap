<#
.SYNOPSIS
    Configuration loader.
.DESCRIPTION
    Downloads and executes a private configuration script.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoOwner = 'tim-atkinson'
$repoName = 'hypnotoad'
$branch = 'main'
$extractPath = Join-Path $env:TEMP $repoName

function Write-Status {
    param([string]$Message, [string]$Colour = 'Cyan')
    Write-Host $Message -ForegroundColor $Colour
}

function Test-WingetAvailable {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Install-ProtonPassCLI {
    Write-Status 'Installing required tools...'
    
    if (-not (Test-WingetAvailable)) {
        Write-Status 'Package manager not available.' 'Red'
        return $false
    }

    try {
        $process = Start-Process -FilePath 'winget' -ArgumentList @(
            'install', 
            '--id', 'Proton.Pass.CLI',
            '--accept-source-agreements',
            '--accept-package-agreements',
            '--silent'
        ) -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -eq 0) {
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + 
                        [System.Environment]::GetEnvironmentVariable("Path","User")
            return $true
        } else {
            return $false
        }
    } catch {
        return $false
    }
}

function Get-ProtonPassCLI {
    foreach ($cmd in @('proton-pass', 'pass')) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            return $cmd
        }
    }
    return $null
}

function Test-ProtonPassAuthenticated {
    param([string]$PassCli)
    try {
        $authInfo = & $PassCli auth info 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Invoke-ProtonPassLogin {
    param([string]$PassCli)
    try {
        & $PassCli auth login
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Execution Policy
$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currentPolicy -eq 'Restricted' -or $currentPolicy -eq 'AllSigned') {
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    } catch {
        Write-Status 'Failed to set execution policy.' 'Red'
        exit 1
    }
}

# PowerShell Version
if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Status 'PowerShell 5.1 or later required.' 'Red'
    exit 1
}

# TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Ensure CLI available
$passCli = Get-ProtonPassCLI

if (-not $passCli) {
    $installed = Install-ProtonPassCLI
    if (-not $installed) {
        Write-Status 'Setup failed.' 'Red'
        exit 1
    }
    $passCli = Get-ProtonPassCLI
    if (-not $passCli) {
        Write-Status 'Setup incomplete.' 'Red'
        exit 1
    }
}

# Authenticate
if (-not (Test-ProtonPassAuthenticated -PassCli $passCli)) {
    $authenticated = Invoke-ProtonPassLogin -PassCli $passCli
    if (-not $authenticated) {
        Write-Status 'Authentication failed.' 'Red'
        exit 1
    }
}

# Retrieve credentials
$token = $null
$headers = $null

try {
    $token = & $passCli item get --vault Bootstrap --name github-pat --field token 2>&1
    if ($LASTEXITCODE -eq 0 -and $token) {
        $headers = @{ Authorization = "token $token" }
    } else {
        Write-Status 'Credentials not found.' 'Red'
        exit 1
    }
} catch {
    Write-Status 'Credentials retrieval failed.' 'Red'
    exit 1
}

# Download
$zipUrl = "https://github.com/$repoOwner/$repoName/archive/refs/heads/$branch.zip"
$zipPath = Join-Path $env:TEMP "$repoName.zip"

try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -Headers $headers -UseBasicParsing
} catch {
    Write-Status 'Download failed.' 'Red'
    exit 1
}

if (-not (Test-Path $zipPath)) {
    Write-Status 'Download failed.' 'Red'
    exit 1
}

# Extract
if (Test-Path $extractPath) {
    Remove-Item -Path $extractPath -Recurse -Force
}

try {
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
    $extractedFolder = Join-Path $env:TEMP "$repoName-$branch"
    if (Test-Path $extractedFolder) {
        Rename-Item -Path $extractedFolder -NewName $repoName -Force
    }
} catch {
    Write-Status 'Extraction failed.' 'Red'
    exit 1
} finally {
    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $extractPath 'bootstrap.ps1'))) {
    Write-Status 'Setup incomplete.' 'Red'
    exit 1
}

# Execute
$mainScript = Join-Path $extractPath 'bootstrap.ps1'

try {
    & $mainScript
} catch {
    Write-Status 'Execution failed.' 'Red'
    exit 1
}
