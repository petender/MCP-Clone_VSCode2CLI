param(
    [string]$InputPath,

    [string]$OutputPath,

    [ValidateSet('VsCodeToCopilot', 'CopilotToVsCode', 'KeepInSync')]
    [string]$Direction,

    [string]$VsCodePath,

    [string]$CopilotPath,

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

function Get-DefaultCopilotMcpPath {
    param([string]$UserHomePath)

    return (Join-Path $UserHomePath '.copilot/mcp-config.json')
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

function Convert-ToOrderedMap {
    param([Parameter(Mandatory = $true)]$Value)

    if ($null -eq $Value) {
        return [ordered]@{}
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $mapped = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $mapped[[string]$key] = $Value[$key]
        }
        return $mapped
    }

    if ($Value -is [pscustomobject]) {
        $mapped = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $mapped[$prop.Name] = $prop.Value
        }
        return $mapped
    }

    throw 'Expected an object map.'
}

function Get-ServersObject {
    param([Parameter(Mandatory = $true)]$Parsed)

    $serversProp = $Parsed.PSObject.Properties['servers']
    if ($null -ne $serversProp -and $null -ne $serversProp.Value) {
        return Convert-ToOrderedMap -Value $serversProp.Value
    }

    $mcpServersProp = $Parsed.PSObject.Properties['mcpServers']
    if ($null -ne $mcpServersProp -and $null -ne $mcpServersProp.Value) {
        return Convert-ToOrderedMap -Value $mcpServersProp.Value
    }

    throw "Input must contain a top-level 'servers' or 'mcpServers' object."
}

function Convert-StringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('Copilot', 'VsCode')][string]$Target,
        [System.Collections.Generic.HashSet[string]]$Vars
    )

    $result = [string]$Value

    if ($Target -eq 'Copilot') {
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

    $plainEnvRegex = '\$([A-Za-z_][A-Za-z0-9_]*)'
    while ($result -match $plainEnvRegex) {
        $envName = [string]$Matches[1]
        [void]$Vars.Add($envName)
        $result = [regex]::Replace($result, [regex]::Escape("`$$envName"), "`${env:$envName}", 1)
    }

    return $result
}

function Convert-Value {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('Copilot', 'VsCode')][string]$Target,
        [System.Collections.Generic.HashSet[string]]$Vars
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return Convert-StringValue -Value ([string]$Value) -Target $Target -Vars $Vars
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $converted = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $converted[$key] = Convert-Value -Value $Value[$key] -Target $Target -Vars $Vars
        }
        return $converted
    }

    if ($Value -is [pscustomobject]) {
        $converted = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $converted[$prop.Name] = Convert-Value -Value $prop.Value -Target $Target -Vars $Vars
        }
        return $converted
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$list.Add((Convert-Value -Value $item -Target $Target -Vars $Vars))
        }
        return ,$list
    }

    return $Value
}

function New-UniqueServerName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)]$TargetMap
    )

    $candidate = $BaseName
    $suffix = 1
    while ($TargetMap.Contains($candidate)) {
        $suffix++
        $candidate = "${BaseName}_$suffix"
    }
    return $candidate
}

function Convert-Servers {
    param(
        [Parameter(Mandatory = $true)]$SourceServers,
        [Parameter(Mandatory = $true)][ValidateSet('Copilot', 'VsCode')][string]$Target
    )

    $sourceMap = Convert-ToOrderedMap -Value $SourceServers
    $targetServers = [ordered]@{}

    foreach ($serverProp in $sourceMap.GetEnumerator()) {
        $originalName = [string]$serverProp.Key
        $serverData = $serverProp.Value

        if (($serverData -isnot [System.Collections.IDictionary]) -and ($serverData -isnot [pscustomobject])) {
            throw "Server '$originalName' is not an object."
        }

        $nameCandidate = if ($Target -eq 'Copilot') { Normalize-ServerName -Name $originalName } else { $originalName }
        $nameToUse = New-UniqueServerName -BaseName $nameCandidate -TargetMap $targetServers

        $envVars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $convertedServer = Convert-Value -Value $serverData -Target $Target -Vars $envVars

        if ($convertedServer -isnot [System.Collections.IDictionary]) {
            throw "Server '$originalName' is not an object after conversion."
        }

        if (-not $convertedServer.Contains('env')) {
            $convertedServer['env'] = [ordered]@{}
        }
        elseif (($convertedServer['env'] -isnot [System.Collections.IDictionary]) -and ($convertedServer['env'] -isnot [pscustomobject])) {
            throw "Server '$originalName' has a non-object 'env' field."
        }
        else {
            $convertedServer['env'] = Convert-ToOrderedMap -Value $convertedServer['env']
        }

        foreach ($envVar in $envVars) {
            if (-not $convertedServer['env'].Contains($envVar)) {
                if ($Target -eq 'Copilot') {
                    $convertedServer['env'][$envVar] = "`$$envVar"
                }
                else {
                    $convertedServer['env'][$envVar] = "`${env:$envVar}"
                }
            }
        }

        if ($convertedServer['env'].Count -eq 0) {
            $convertedServer.Remove('env')
        }

        $targetServers[$nameToUse] = $convertedServer
    }

    return $targetServers
}

function Merge-Servers {
    param(
        [Parameter(Mandatory = $true)]$BaseServers,
        [Parameter(Mandatory = $true)]$IncomingServers,
        [Parameter(Mandatory = $true)][ValidateSet('Copilot', 'VsCode')][string]$Target
    )

    $result = [ordered]@{}
    $added = 0
    $renamed = 0
    $unchanged = 0

    $baseMap = Convert-ToOrderedMap -Value $BaseServers
    $incomingMap = Convert-ToOrderedMap -Value $IncomingServers

    foreach ($entry in $baseMap.GetEnumerator()) {
        $result[$entry.Key] = $entry.Value
    }

    foreach ($entry in $incomingMap.GetEnumerator()) {
        $name = [string]$entry.Key
        $value = $entry.Value

        if (-not $result.Contains($name)) {
            $result[$name] = $value
            $added++
            continue
        }

        $existingJson = $result[$name] | ConvertTo-Json -Depth 100 -Compress
        $incomingJson = $value | ConvertTo-Json -Depth 100 -Compress
        if ($existingJson -eq $incomingJson) {
            $unchanged++
            continue
        }

        $baseName = if ($Target -eq 'Copilot') { Normalize-ServerName -Name $name } else { $name }
        $newName = New-UniqueServerName -BaseName $baseName -TargetMap $result
        $result[$newName] = $value
        $added++
        $renamed++
    }

    return [pscustomobject]@{
        Servers = $result
        Added = $added
        Renamed = $renamed
        Unchanged = $unchanged
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    try {
        return ($raw | ConvertFrom-Json -Depth 100)
    }
    catch {
        throw "Failed to parse JSON from '$Path'. Ensure it's valid JSON (not JSONC with comments/trailing commas)."
    }
}

function Write-Config {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Copilot', 'VsCode')][string]$Target,
        [Parameter(Mandatory = $true)]$Servers
    )

    $outputObject = if ($Target -eq 'Copilot') {
        [ordered]@{ mcpServers = $Servers }
    }
    else {
        [ordered]@{ servers = $Servers }
    }

    $outputJson = $outputObject | ConvertTo-Json -Depth 100
    $outputDir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $outputJson -Encoding UTF8
}

function Resolve-Direction {
    param([string]$ProvidedDirection)

    if (-not [string]::IsNullOrWhiteSpace($ProvidedDirection)) {
        return $ProvidedDirection
    }

    Write-Host 'Select sync direction:'
    Write-Host '  1) VS Code -> Copilot CLI'
    Write-Host '  2) Copilot CLI -> VS Code'
    Write-Host '  3) Keep both in sync'

    try {
        $choice = (Read-Host 'Enter 1, 2, or 3').Trim()
    }
    catch {
        $choice = '1'
    }

    switch ($choice) {
        '1' { return 'VsCodeToCopilot' }
        '2' { return 'CopilotToVsCode' }
        '3' { return 'KeepInSync' }
        default { throw "Invalid choice '$choice'. Use 1, 2, or 3, or pass -Direction explicitly." }
    }
}

function Resolve-Paths {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedDirection,
        [string]$InputArg,
        [string]$OutputArg,
        [string]$ExplicitVsCode,
        [string]$ExplicitCopilot,
        [string]$UserHomePath
    )

    $resolvedVsCode = $ExplicitVsCode
    $resolvedCopilot = $ExplicitCopilot

    if ([string]::IsNullOrWhiteSpace($resolvedVsCode) -and -not [string]::IsNullOrWhiteSpace($InputArg)) {
        $resolvedVsCode = $InputArg
    }

    if ([string]::IsNullOrWhiteSpace($resolvedCopilot) -and -not [string]::IsNullOrWhiteSpace($OutputArg)) {
        $resolvedCopilot = $OutputArg
    }

    if ($ResolvedDirection -eq 'CopilotToVsCode') {
        if ([string]::IsNullOrWhiteSpace($resolvedCopilot) -and -not [string]::IsNullOrWhiteSpace($InputArg)) {
            $resolvedCopilot = $InputArg
        }
        if ([string]::IsNullOrWhiteSpace($resolvedVsCode) -and -not [string]::IsNullOrWhiteSpace($OutputArg)) {
            $resolvedVsCode = $OutputArg
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedVsCode)) {
        $resolvedVsCode = Get-DefaultVsCodeMcpPath -UserHomePath $UserHomePath
    }

    if ([string]::IsNullOrWhiteSpace($resolvedCopilot)) {
        $resolvedCopilot = Get-DefaultCopilotMcpPath -UserHomePath $UserHomePath
    }

    return [pscustomobject]@{
        VsCodePath = $resolvedVsCode
        CopilotPath = $resolvedCopilot
    }
}

$resolvedDirection = Resolve-Direction -ProvidedDirection $Direction

$paths = Resolve-Paths -ResolvedDirection $resolvedDirection -InputArg $InputPath -OutputArg $OutputPath -ExplicitVsCode $VsCodePath -ExplicitCopilot $CopilotPath -UserHomePath $UserHome

if ([string]::IsNullOrWhiteSpace($paths.VsCodePath)) {
    throw "Could not auto-detect a VS Code MCP config. Pass -VsCodePath explicitly."
}

Write-Host "Direction   : $resolvedDirection"
Write-Host "VS Code path: $($paths.VsCodePath)"
Write-Host "Copilot path: $($paths.CopilotPath)"

$hasVsCodeFile = Test-Path -LiteralPath $paths.VsCodePath
$hasCopilotFile = Test-Path -LiteralPath $paths.CopilotPath

if ($resolvedDirection -eq 'VsCodeToCopilot') {
    if (-not $hasVsCodeFile) {
        throw "Input file not found: $($paths.VsCodePath)"
    }

    $sourceParsed = Read-JsonFile -Path $paths.VsCodePath
    $incoming = Convert-Servers -SourceServers (Get-ServersObject -Parsed $sourceParsed) -Target 'Copilot'

    $existing = [ordered]@{}
    if ($hasCopilotFile) {
        $existingParsed = Read-JsonFile -Path $paths.CopilotPath
        $existing = Get-ServersObject -Parsed $existingParsed
    }

    $mergeResult = Merge-Servers -BaseServers $existing -IncomingServers $incoming -Target 'Copilot'
    Write-Config -Path $paths.CopilotPath -Target 'Copilot' -Servers $mergeResult.Servers

    Write-Host "Merged MCP config written to: $($paths.CopilotPath)"
    Write-Host "Added servers: $($mergeResult.Added); renamed due to conflicts: $($mergeResult.Renamed); unchanged duplicates: $($mergeResult.Unchanged)"
    return
}

if ($resolvedDirection -eq 'CopilotToVsCode') {
    if (-not $hasCopilotFile) {
        throw "Input file not found: $($paths.CopilotPath)"
    }

    $sourceParsed = Read-JsonFile -Path $paths.CopilotPath
    $incoming = Convert-Servers -SourceServers (Get-ServersObject -Parsed $sourceParsed) -Target 'VsCode'

    $existing = [ordered]@{}
    if ($hasVsCodeFile) {
        $existingParsed = Read-JsonFile -Path $paths.VsCodePath
        $existing = Get-ServersObject -Parsed $existingParsed
    }

    $mergeResult = Merge-Servers -BaseServers $existing -IncomingServers $incoming -Target 'VsCode'
    Write-Config -Path $paths.VsCodePath -Target 'VsCode' -Servers $mergeResult.Servers

    Write-Host "Merged MCP config written to: $($paths.VsCodePath)"
    Write-Host "Added servers: $($mergeResult.Added); renamed due to conflicts: $($mergeResult.Renamed); unchanged duplicates: $($mergeResult.Unchanged)"
    return
}

$vsCodeServers = [ordered]@{}
$copilotServers = [ordered]@{}

if ($hasVsCodeFile) {
    $vsCodeParsed = Read-JsonFile -Path $paths.VsCodePath
    $vsCodeServers = Get-ServersObject -Parsed $vsCodeParsed
}

if ($hasCopilotFile) {
    $copilotParsed = Read-JsonFile -Path $paths.CopilotPath
    $copilotServers = Get-ServersObject -Parsed $copilotParsed
}

$fromVsCode = Convert-Servers -SourceServers $vsCodeServers -Target 'Copilot'
$mergedCopilotResult = Merge-Servers -BaseServers $copilotServers -IncomingServers $fromVsCode -Target 'Copilot'
$finalCopilotServers = $mergedCopilotResult.Servers

$finalVsCodeServers = Convert-Servers -SourceServers $finalCopilotServers -Target 'VsCode'

Write-Config -Path $paths.CopilotPath -Target 'Copilot' -Servers $finalCopilotServers
Write-Config -Path $paths.VsCodePath -Target 'VsCode' -Servers $finalVsCodeServers

Write-Host "Synchronized both files:"
Write-Host "  VS Code : $($paths.VsCodePath)"
Write-Host "  Copilot : $($paths.CopilotPath)"
Write-Host "Copilot merge added: $($mergedCopilotResult.Added); renamed due to conflicts: $($mergedCopilotResult.Renamed); unchanged duplicates: $($mergedCopilotResult.Unchanged)"
