param(
    [string]$InputPath,

    [string]$OutputPath,

    [string]$UserHome = [Environment]::GetFolderPath('UserProfile')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultVsCodeMcpPath {
    param([string]$UserHomePath)

    $candidates = New-Object System.Collections.Generic.List[string]
    $cwd = (Get-Location).Path
    $candidates.Add((Join-Path $cwd 'mcp.json'))
    $candidates.Add((Join-Path $cwd '.vscode/mcp.json'))

    if ($IsWindows) {
        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $candidates.Add((Join-Path $env:APPDATA 'Code/User/mcp.json'))
        }
    }
    elseif ($IsMacOS) {
        $candidates.Add((Join-Path $UserHomePath 'Library/Application Support/Code/User/mcp.json'))
    }
    else {
        $candidates.Add((Join-Path $UserHomePath '.config/Code/User/mcp.json'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Normalize-EnvName {
    param([string]$Name)

    $normalized = ($Name -replace '[^A-Za-z0-9_]', '_').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Cannot normalize environment variable name from '$Name'."
    }
    return $normalized
}

function Normalize-ServerName {
    param([string]$Name)

    $normalized = $Name -replace '[^A-Za-z0-9_-]', '_'
    $normalized = $normalized.Trim('_')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Cannot normalize server name from '$Name'."
    }
    return $normalized
}

function Convert-Value {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [System.Collections.Generic.HashSet[string]]$Vars
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $result = [string]$Value

        $inputRegex = '\$\{input:([^}]+)\}'
        while ($result -match $inputRegex) {
            $rawName = $Matches[1]
            $envName = Normalize-EnvName -Name $rawName
            [void]$Vars.Add($envName)
            $result = [regex]::Replace($result, [regex]::Escape("`$`{input:$rawName`}"), "`$$envName", 1)
        }

        $envRegex = '\$\{env:([^}]+)\}'
        while ($result -match $envRegex) {
            $rawName = $Matches[1]
            $envName = Normalize-EnvName -Name $rawName
            [void]$Vars.Add($envName)
            $result = [regex]::Replace($result, [regex]::Escape("`$`{env:$rawName`}"), "`$$envName", 1)
        }

        return $result
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $converted = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $converted[$key] = Convert-Value -Value $Value[$key] -Vars $Vars
        }
        return $converted
    }

    if ($Value -is [pscustomobject]) {
        $converted = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $converted[$prop.Name] = Convert-Value -Value $prop.Value -Vars $Vars
        }
        return $converted
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$list.Add((Convert-Value -Value $item -Vars $Vars))
        }
        return ,$list
    }

    return $Value
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Get-DefaultVsCodeMcpPath -UserHomePath $UserHome
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $UserHome '.copilot/mcp-config.json'
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    throw "Could not auto-detect a VS Code MCP config. Pass -InputPath explicitly."
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

Write-Host "Using input : $InputPath"
Write-Host "Using output: $OutputPath"

$raw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8

try {
    $parsed = $raw | ConvertFrom-Json -Depth 100
}
catch {
    throw "Failed to parse JSON from '$InputPath'. Ensure it's valid JSON (not JSONC with comments/trailing commas)."
}

$sourceServers = $null
if ($null -ne $parsed.servers) {
    $sourceServers = $parsed.servers
}
elseif ($null -ne $parsed.mcpServers) {
    $sourceServers = $parsed.mcpServers
}
else {
    throw "Input must contain a top-level 'servers' or 'mcpServers' object."
}

$targetServers = [ordered]@{}

foreach ($serverProp in $sourceServers.PSObject.Properties) {
    $originalName = [string]$serverProp.Name
    $safeName = Normalize-ServerName -Name $originalName

    $nameToUse = $safeName
    $suffix = 1
    while ($targetServers.Contains($nameToUse)) {
        $suffix++
        $nameToUse = "${safeName}_$suffix"
    }

    $envVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $convertedServer = Convert-Value -Value $serverProp.Value -Vars $envVars

    if ($convertedServer -isnot [System.Collections.IDictionary]) {
        throw "Server '$originalName' is not an object."
    }

    if (-not $convertedServer.Contains('env')) {
        $convertedServer['env'] = [ordered]@{}
    }
    elseif ($convertedServer['env'] -isnot [System.Collections.IDictionary]) {
        throw "Server '$originalName' has a non-object 'env' field."
    }

    foreach ($envVar in $envVars) {
        if (-not $convertedServer['env'].Contains($envVar)) {
            $convertedServer['env'][$envVar] = "`$$envVar"
        }
    }

    if ($convertedServer['env'].Count -eq 0) {
        $convertedServer.Remove('env')
    }

    $targetServers[$nameToUse] = $convertedServer
}

$outputObject = [ordered]@{
    mcpServers = $targetServers
}

$outputJson = $outputObject | ConvertTo-Json -Depth 100
$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $outputJson -Encoding UTF8
Write-Host "Converted MCP config written to: $OutputPath"
