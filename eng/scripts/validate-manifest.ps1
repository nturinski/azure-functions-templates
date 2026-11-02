<#
.SYNOPSIS
    Validates the canonical manifest schema and connector operation ownership.

.DESCRIPTION
    Adds semantic checks that JSON Schema cannot express: unique operation IDs
    and function registrations, disjoint owned paths, and shared-file protection.
    No project files are modified and no network access is required.
#>

#Requires -Version 7.0

[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(ParameterSetName = 'Path')]
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\..\Functions.Templates\Template-Manifest\manifest.json'),

    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string]$ManifestJson,

    [string]$SchemaPath = (Join-Path $PSScriptRoot '..\..\Functions.Templates\Template-Manifest\schemas\manifest.schema.json')
)

$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $ManifestJson = Get-Content -LiteralPath $ManifestPath -Raw
}

if (-not (Test-Json -Json $ManifestJson -SchemaFile $SchemaPath -ErrorAction Stop)) {
    throw 'Manifest schema validation failed.'
}

$manifest = ConvertFrom-Json -InputObject $ManifestJson -AsHashtable
$errors = [System.Collections.Generic.List[string]]::new()

if ($manifest.totalTemplates -ne $manifest.templates.Count) {
    $errors.Add("totalTemplates must equal templates.Count ($($manifest.templates.Count)).")
}

$sharedPaths = @(
    '.git',
    '.gitignore',
    '.funcignore',
    '.vscode',
    'README.md',
    'LICENSE',
    'LICENSE.txt',
    'host.json',
    'local.settings.json',
    'local.settings.example.json',
    'connector-template.json',
    'azure.yaml',
    'package.json',
    'package-lock.json',
    'tsconfig.json',
    'function_app.py',
    'requirements.txt',
    'pyproject.toml',
    'Program.cs',
    'O365Functions.cs',
    'SharePointFunctions.cs',
    'NuGet.config',
    'src/index.ts',
    'infra/main.bicep',
    'infra/main.parameters.json',
    'infra/abbreviations.json',
    'infra/connectorNamespace.bicep',
    'infra/poll-trigger.bicep',
    'infra/scripts/prepare.ps1',
    'infra/scripts/postdeploy.ps1'
)
$comparison = [System.StringComparison]::OrdinalIgnoreCase

foreach ($template in $manifest.templates) {
    if (-not $template.ContainsKey('connectorTrigger')) {
        continue
    }

    $operationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $functionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ownedPaths = [System.Collections.Generic.List[object]]::new()

    foreach ($operation in $template.connectorTrigger.operations) {
        $label = "$($template.id)/$($operation.operationId)"

        if (-not $operationIds.Add($operation.operationId)) {
            $errors.Add("${label}: duplicate operationId.")
        }
        if (-not $functionNames.Add($operation.functionName)) {
            $errors.Add("${label}: duplicate functionName '$($operation.functionName)' (case-insensitive).")
        }

        foreach ($ownedPath in $operation.ownedPaths) {
            foreach ($segment in $ownedPath.Split('/')) {
                if ($segment -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)') {
                    $errors.Add("${label}: owned path '$ownedPath' contains a reserved device name.")
                }
            }

            if ($ownedPath -match '^[^/]+\.(csproj|fsproj|sln|slnx)$') {
                $errors.Add("${label}: owned path '$ownedPath' is a shared project file.")
            }

            foreach ($sharedPath in $sharedPaths) {
                if ([string]::Equals($ownedPath, $sharedPath, $comparison) -or
                    $ownedPath.StartsWith("$sharedPath/", $comparison) -or
                    $sharedPath.StartsWith("$ownedPath/", $comparison)) {
                    $errors.Add("${label}: owned path '$ownedPath' overlaps shared path '$sharedPath'.")
                }
            }

            foreach ($previous in $ownedPaths) {
                if ([string]::Equals($ownedPath, $previous.Path, $comparison) -or
                    $ownedPath.StartsWith("$($previous.Path)/", $comparison) -or
                    $previous.Path.StartsWith("$ownedPath/", $comparison)) {
                    $errors.Add("${label}: owned path '$ownedPath' overlaps '$($previous.Path)' owned by '$($previous.OperationId)'.")
                }
            }

            $ownedPaths.Add([pscustomobject]@{
                Path = $ownedPath
                OperationId = $operation.operationId
            })
        }
    }
}

if ($errors.Count -gt 0) {
    throw "Manifest validation failed:`n$($errors -join "`n")"
}

Write-Host "Manifest validation passed ($($manifest.templates.Count) templates)."
