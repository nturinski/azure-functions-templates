<#
.SYNOPSIS
    Runs dependency-free manifest schema and ownership regression tests.
#>

#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'validate-manifest.ps1'
$manifestPath = Join-Path $PSScriptRoot '..\..\Functions.Templates\Template-Manifest\manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$passed = 0

& $validator -ManifestPath $manifestPath
$passed++

$roundTrippedManifest = $manifest | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
for ($templateIndex = 0; $templateIndex -lt $manifest.templates.Count; $templateIndex++) {
    $template = $manifest.templates[$templateIndex]
    if ($template.resource -ne 'connector') {
        continue
    }

    if (-not $template.ContainsKey('connectorTrigger') -or $template.gitRef -notmatch '^[0-9a-fA-F]{40}\z') {
        throw "$($template.id): canonical connector entries must include ownership at an immutable commit pin."
    }

    $operations = $template.connectorTrigger.operations
    $roundTrippedOperations = $roundTrippedManifest.templates[$templateIndex].connectorTrigger.operations
    if ($operations.Count -ne $roundTrippedOperations.Count) {
        throw "$($template.id): JSON round-trip changed the operation inventory."
    }
    for ($operationIndex = 0; $operationIndex -lt $operations.Count; $operationIndex++) {
        $before = $operations[$operationIndex]
        $after = $roundTrippedOperations[$operationIndex]
        if ($before.operationId -cne $after.operationId -or
            $before.functionName -cne $after.functionName -or
            ($before.ownedPaths -join "`n") -cne ($after.ownedPaths -join "`n")) {
            throw "$($template.id): JSON round-trip changed operation ownership."
        }
    }
}
$passed += 2

$fixture = [ordered]@{
    '$schema' = $manifest.'$schema'
    generatedAt = $manifest.generatedAt
    version = $manifest.version
    totalTemplates = 1
    languages = @('TypeScript')
    templates = @(
        [ordered]@{
            id = 'ownership-test'
            displayName = 'Ownership test'
            shortDescription = 'Test fixture'
            longDescription = 'Test fixture'
            language = 'TypeScript'
            bindingType = 'trigger'
            resource = 'connector'
            iac = 'bicep'
            priority = 80
            categories = @('connectors')
            repositoryUrl = 'https://github.com/Azure-Samples/functions-connectors-typescript'
            folderPath = '.'
            gitRef = '0123456789abcdef0123456789abcdef01234567'
            connectorTrigger = @{
                operations = @(
                    @{
                        operationId = 'OperationA'
                        functionName = 'FunctionA'
                        ownedPaths = @('src/functions/a.ts', 'infra/operations/a')
                    },
                    @{
                        operationId = 'OperationB'
                        functionName = 'FunctionB'
                        ownedPaths = @('src/functions/ab.ts', 'infra/operations/ab')
                    }
                )
            }
        }
    )
}
$fixtureJson = $fixture | ConvertTo-Json -Depth 100

function New-TestManifest {
    ConvertFrom-Json -InputObject $fixtureJson -AsHashtable
}

function Confirm-ValidManifest {
    param([string]$Name, [object]$Value)

    try {
        & $validator -ManifestJson ($Value | ConvertTo-Json -Depth 100) 6>$null
    } catch {
        throw "${Name}: unexpectedly rejected: $_"
    }
    $script:passed++
}

function Confirm-InvalidManifest {
    param([string]$Name, [scriptblock]$Change, [string]$ExpectedError)

    $value = New-TestManifest
    $null = & $Change $value
    $rejected = $false
    try {
        & $validator -ManifestJson ($value | ConvertTo-Json -Depth 100) 6>$null
    } catch {
        if ($ExpectedError -and -not $_.ToString().Contains($ExpectedError)) {
            throw "${Name}: rejected for the wrong reason: $_"
        }
        $rejected = $true
    }
    if (-not $rejected) {
        throw "${Name}: invalid ownership was accepted."
    }
    $script:passed++
}

Confirm-ValidManifest 'Disjoint files/directories and sibling prefixes' (New-TestManifest)

$legacy = New-TestManifest
$legacy.templates[0].Remove('connectorTrigger')
Confirm-ValidManifest 'Legacy connector without ownership' $legacy
$legacy.templates[0].resource = 'http'
Confirm-ValidManifest 'Non-connector without ownership' $legacy

$legacyManifest = $manifest | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
foreach ($template in $legacyManifest.templates) {
    $template.Remove('connectorTrigger')
}
Confirm-ValidManifest 'All canonical templates without optional ownership' $legacyManifest

$roundTrip = New-TestManifest
$ownershipBefore = $roundTrip.templates[0].connectorTrigger | ConvertTo-Json -Depth 100 -Compress
$roundTrip = $roundTrip | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$ownershipAfter = $roundTrip.templates[0].connectorTrigger | ConvertTo-Json -Depth 100 -Compress
if ($ownershipBefore -cne $ownershipAfter) {
    throw 'JSON round-trip changed the ownership contract.'
}
Confirm-ValidManifest 'JSON round-trip preserves exact ownership' $roundTrip

Confirm-InvalidManifest 'Ownership on a non-connector' {
    param($value)
    $value.templates[0].resource = 'http'
}
Confirm-InvalidManifest 'Ownership on a non-trigger' {
    param($value)
    $value.templates[0].bindingType = 'input'
}
Confirm-InvalidManifest 'Template count mismatch' {
    param($value)
    $value.totalTemplates = 2
} 'totalTemplates'

foreach ($invalid in @($null, @{}, @{ operations = @() }, @{ operations = $null }, @{ operations = @($null) }, @{ operations = 'invalid' })) {
    Confirm-InvalidManifest 'Invalid/missing/empty operations' {
        param($value)
        $value.templates[0].connectorTrigger = $invalid
    }
}

foreach ($field in @('operationId', 'functionName', 'ownedPaths')) {
    Confirm-InvalidManifest "Missing $field" {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].Remove($field)
    }
}

foreach ($field in @('operationId', 'functionName')) {
    foreach ($invalid in @('', ' ', "name`n", 'two names', $null, 42)) {
        Confirm-InvalidManifest "Invalid $field" {
            param($value)
            $value.templates[0].connectorTrigger.operations[0][$field] = $invalid
        }
    }
}

Confirm-InvalidManifest 'Unexpected connectorTrigger field' {
    param($value)
    $value.templates[0].connectorTrigger.extra = $true
}
Confirm-InvalidManifest 'Unexpected operation field' {
    param($value)
    $value.templates[0].connectorTrigger.operations[0].extra = $true
}
Confirm-InvalidManifest 'Duplicate operation IDs' {
    param($value)
    $value.templates[0].connectorTrigger.operations[1].operationId = 'OperationA'
} 'duplicate operationId'
Confirm-InvalidManifest 'Duplicate function registrations' {
    param($value)
    $value.templates[0].connectorTrigger.operations[1].functionName = 'FunctionA'
} 'duplicate functionName'
Confirm-InvalidManifest 'Case-insensitive registration collision' {
    param($value)
    $value.templates[0].connectorTrigger.operations[1].functionName = 'functiona'
} 'duplicate functionName'

foreach ($invalid in @(@(), $null, 'src/functions/a.ts', @($null), @(42))) {
    Confirm-InvalidManifest 'Invalid/empty ownership array' {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].ownedPaths = $invalid
    }
}

foreach ($path in @(
    '', ' ', '.', '..', '/tmp/a.ts', 'C:/a.ts', 'C:\a.ts', '\\server\share\a.ts',
    '//server/share/a.ts', '../a.ts', 'src/../a.ts', 'src/./a.ts', './src/a.ts',
    'src//a.ts', 'src/', 'src\a.ts', 'src/*.ts', 'src/a?.ts', 'src/[ab].ts',
    'src/{a,b}.ts', 'src/a:stream', 'src/a|b.ts', 'src/a<b.ts', 'src/a>b.ts',
    'src/a"b.ts', "src/a`n.ts", "src/a.ts`n", 'src/a.ts.', 'src/a.ts ',
    'src/ /a.ts', 'src/CON.ts', 'src/nul/a.ts'
)) {
    Confirm-InvalidManifest "Unsafe path '$path'" {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].ownedPaths = @($path)
    }
}

foreach ($path in @(
    'host.json', 'HOST.JSON', 'local.settings.json', 'azure.yaml', 'package.json',
    'package-lock.json', 'tsconfig.json', 'function_app.py', 'requirements.txt',
    'Program.cs', 'App.csproj', 'App.fsproj', 'App.sln', 'App.slnx',
    'infra/main.bicep', 'infra/main.parameters.json', 'infra', 'src',
    '.git', '.git/config', '.vscode', '.vscode/launch.json',
    'local.settings.example.json', 'connector-template.json', 'NuGet.config',
    'O365Functions.cs', 'SharePointFunctions.cs', 'infra/connectorNamespace.bicep',
    'infra/poll-trigger.bicep', 'infra/scripts/prepare.ps1',
    'infra/scripts/postdeploy.ps1', 'infra/scripts'
)) {
    Confirm-InvalidManifest "Shared path '$path'" {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].ownedPaths = @($path)
    } 'shared'
}

foreach ($paths in @(
    @('src/functions/a.ts', 'src/functions/a.ts'),
    @('src/functions/a.ts', 'SRC/functions/A.ts'),
    @('src/functions/a', 'src/functions/a/file.ts'),
    @('src/functions/a/file.ts', 'src/functions/a')
)) {
    Confirm-InvalidManifest 'Duplicate/overlapping paths in one operation' {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].ownedPaths = $paths
    }
}

foreach ($paths in @(
    @('src/functions/a.ts', 'src/functions/a.ts'),
    @('src/functions/a.ts', 'SRC/functions/A.ts'),
    @('src/functions/a', 'src/functions/a/file.ts'),
    @('src/functions/a/file.ts', 'src/functions/a')
)) {
    Confirm-InvalidManifest 'Duplicate/overlapping paths across operations' {
        param($value)
        $value.templates[0].connectorTrigger.operations[0].ownedPaths = @($paths[0])
        $value.templates[0].connectorTrigger.operations[1].ownedPaths = @($paths[1])
    } 'overlaps'
}

Write-Host "Manifest schema/ownership regression tests passed: $passed cases."
