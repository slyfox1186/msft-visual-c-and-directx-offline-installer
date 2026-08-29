Set-StrictMode -Version 2.0

Import-Module -Name (Join-Path $PSScriptRoot 'ConsoleUI.psm1') -ErrorAction Stop

$script:AllowedMicrosoftHostPattern = '\A(?:aka\.ms|builds\.dotnet\.microsoft\.com|download\.microsoft\.com|download\.visualstudio\.microsoft\.com)\z'
$script:AllowedMicrosoftDiscoveryHostPattern = '\A(?:learn\.microsoft\.com|www\.microsoft\.com)\z'
$script:StableChannelPattern = '\A\d{1,3}\.\d{1,2}\z'
$script:StableVersionPattern = '\A\d{1,3}\.\d{1,5}\.\d{1,5}\z'
$script:StableSdkVersionPattern = '\A(?<major>\d{1,3})\.(?<minor>\d{1,2})\.(?<band>\d)(?<patch>\d{2})\z'
$script:PrereleaseVersionPattern = '(?i)-(?:preview|rc|beta|alpha|servicing|daily|dev|ci|rtm|go-live)\b'
$script:DotNetSupportPhasePattern = '\A(?:active|maintenance)\z'
$script:DotNetReleaseTypePattern = '\A(?:lts|sts)\z'
$script:VisualCppFileVersionPattern = '\A\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}\z'
$script:VisualCppV14VersionPattern = '\A14\.(?<minor>\d{1,3})\.(?<build>\d{1,5})\.(?<revision>\d{1,5})\z'
$script:VersionInTextPattern = '(?<version>\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5})'
$script:Sha256Pattern = '\A[A-Fa-f0-9]{64}\z'
$script:Sha512Pattern = '\A[A-Fa-f0-9]{128}\z'
$script:InstallerFileNamePattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.exe\z'
$script:DotNetReleasesIndexUri = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
$script:DotNetLatestVersionUriTemplate = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/{0}/latest.version'
$script:MicrosoftDownloadCenterUriTemplate = 'https://www.microsoft.com/en-us/download/details.aspx?id={0}'
$script:VisualCppDocumentationUri = 'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170&accept=text/markdown'
$script:MaximumDiscoveryDocumentBytes = 5MB
$script:RemoteRegexTimeout = [timespan]::FromSeconds(2)

function Test-AllowedMicrosoftUri {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        $parsedUri = [uri]$Uri
        if (-not $parsedUri.IsAbsoluteUri) { return $false }
        if ($parsedUri.Scheme -cne 'https') { return $false }
        if ($parsedUri.Port -ne 443) { return $false }
        if (-not [string]::IsNullOrEmpty($parsedUri.UserInfo)) { return $false }
        return $parsedUri.DnsSafeHost -match $script:AllowedMicrosoftHostPattern
    }
    catch {
        return $false
    }
}

function Assert-MicrosoftUri {
    [CmdletBinding()]
    [OutputType([uri])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if (-not (Test-AllowedMicrosoftUri -Uri $Uri)) {
        throw "Rejected non-Microsoft or non-HTTPS URL: $Uri"
    }

    return [uri]$Uri
}

function Test-AllowedMicrosoftDiscoveryUri {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        $parsedUri = [uri]$Uri
        if (-not $parsedUri.IsAbsoluteUri) { return $false }
        if ($parsedUri.Scheme -cne 'https') { return $false }
        if ($parsedUri.Port -ne 443) { return $false }
        if (-not [string]::IsNullOrEmpty($parsedUri.UserInfo)) { return $false }
        return $parsedUri.DnsSafeHost -match $script:AllowedMicrosoftDiscoveryHostPattern
    }
    catch {
        return $false
    }
}

function Assert-MicrosoftDiscoveryUri {
    [CmdletBinding()]
    [OutputType([uri])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if (-not (Test-AllowedMicrosoftDiscoveryUri -Uri $Uri)) {
        throw "Rejected non-Microsoft or non-HTTPS discovery URL: $Uri"
    }

    return [uri]$Uri
}

function Test-StableVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [switch]$Channel
    )

    if ($Channel) {
        return $Version -match $script:StableChannelPattern
    }

    return $Version -match $script:StableVersionPattern
}

function Test-StableDotNetSdkVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($Version -match $script:PrereleaseVersionPattern) { return $false }
    return $Version -match $script:StableSdkVersionPattern
}

function Assert-Sha512 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash
    )

    if ($Hash -notmatch $script:Sha512Pattern) {
        throw 'SHA-512 metadata must contain exactly 128 hexadecimal characters.'
    }
}

function Assert-Sha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash
    )

    if ($Hash -notmatch $script:Sha256Pattern) {
        throw 'SHA-256 metadata must contain exactly 64 hexadecimal characters.'
    }
}

function ConvertFrom-DotNetLatestVersionText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$VersionText
    )

    $tokens = @(-split $VersionText)
    if ($tokens.Count -eq 0) {
        throw 'The Microsoft latest.version response was empty.'
    }

    $version = [string]$tokens[$tokens.Count - 1]
    if (-not (Test-StableDotNetSdkVersion -Version $version)) {
        throw "The Microsoft latest.version response did not end with a stable SDK version: $version"
    }
    return $version
}

function Assert-InstallerFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ($FileName -notmatch $script:InstallerFileNamePattern) {
        throw "Rejected unsafe installer filename: $FileName"
    }
}

function Get-CurlArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [bool]$ShowProgress = $true,

        [ValidateSet('Package', 'Discovery')]
        [string]$UriPurpose = 'Package'
    )

    $validatedUri = if ($UriPurpose -eq 'Discovery') {
        Assert-MicrosoftDiscoveryUri -Uri $Uri
    }
    else {
        Assert-MicrosoftUri -Uri $Uri
    }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        throw 'A nonempty curl destination path is required.'
    }

    $arguments = @(
        '--fail',
        '--location',
        '--max-redirs', '10',
        '--proto', '=https',
        '--proto-redir', '=https',
        '--tlsv1.2',
        '--retry', '4',
        '--retry-delay', '2',
        '--retry-connrefused',
        '--connect-timeout', '30',
        '--max-time', '1800'
    )
    if ($ShowProgress) {
        $arguments += '--progress-bar'
    }
    else {
        $arguments += '--silent'
    }
    $arguments += @(
        '--show-error',
        '--output', $DestinationPath,
        '--write-out', '%{url_effective}',
        '--url', $validatedUri.AbsoluteUri
    )
    return $arguments
}

function Get-CurlExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $commandName = 'curl'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $commandName = 'curl.exe'
    }

    $command = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw "$commandName is required but was not found in PATH."
    }

    return $command.Source
}

function Get-CurlVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $curlExecutable = Get-CurlExecutable
    $versionOutput = @(& $curlExecutable --version)
    $curlExitCode = $LASTEXITCODE
    if ($curlExitCode -ne 0 -or $versionOutput.Count -eq 0) {
        throw "Unable to determine the installed curl version (exit code $curlExitCode)."
    }

    $versionLine = [string]$versionOutput[0]
    if ($versionLine -notmatch '\Acurl\s+([^\s]+)') {
        throw "Unable to parse the installed curl version from: $versionLine"
    }
    return [string]$matches[1]
}

function Invoke-CurlDownload {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [string]$DisplayName = 'Microsoft file',

        [bool]$ShowProgress = $true,

        [ValidateSet('Package', 'Discovery')]
        [string]$UriPurpose = 'Package'
    )

    $validatedUri = if ($UriPurpose -eq 'Discovery') {
        Assert-MicrosoftDiscoveryUri -Uri $Uri
    }
    else {
        Assert-MicrosoftUri -Uri $Uri
    }
    $fullDestinationPath = [IO.Path]::GetFullPath($DestinationPath)
    $destinationDirectory = Split-Path -Parent $fullDestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        throw "Curl destination directory does not exist: $destinationDirectory"
    }
    if (Test-Path -LiteralPath $fullDestinationPath) {
        throw "Refusing to overwrite an existing download: $fullDestinationPath"
    }

    $curlExecutable = Get-CurlExecutable
    $curlArguments = Get-CurlArgument -Uri $validatedUri.AbsoluteUri -DestinationPath $fullDestinationPath -ShowProgress $ShowProgress -UriPurpose $UriPurpose
    $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-InstallerStatus -State Download -Message ("Downloading: {0} | Source: {1}" -f $DisplayName, $validatedUri.DnsSafeHost)

    try {
        $effectiveUriText = (& $curlExecutable @curlArguments | Out-String).Trim()
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            throw "curl.exe failed with exit code $curlExitCode while downloading $($validatedUri.AbsoluteUri)"
        }
        if ([string]::IsNullOrWhiteSpace($effectiveUriText)) {
            throw 'curl.exe did not report an effective URL.'
        }

        $effectiveUri = if ($UriPurpose -eq 'Discovery') {
            Assert-MicrosoftDiscoveryUri -Uri $effectiveUriText
        }
        else {
            Assert-MicrosoftUri -Uri $effectiveUriText
        }
        $downloadedFile = Get-Item -LiteralPath $fullDestinationPath -Force -ErrorAction Stop
        if ($downloadedFile.PSIsContainer -or $downloadedFile.Length -le 0) {
            throw "curl.exe did not create a nonempty regular file: $fullDestinationPath"
        }

        $downloadTimer.Stop()
        Write-InstallerStatus -State Ok -Message ("Downloaded: {0} | {1} | {2} | Source: {3}" -f $DisplayName, (Format-InstallerByteSize -Bytes $downloadedFile.Length), (Format-InstallerDuration -Duration $downloadTimer.Elapsed), $effectiveUri.DnsSafeHost)

        return [pscustomobject]@{
            SourceUri    = $validatedUri.AbsoluteUri
            EffectiveUri = $effectiveUri.AbsoluteUri
            Path         = $downloadedFile.FullName
            Length       = $downloadedFile.Length
        }
    }
    catch {
        $downloadTimer.Stop()
        Write-InstallerStatus -State Failed -Message ("Download failed for {0}: {1}" -f $DisplayName, $_.Exception.Message)
        Remove-Item -LiteralPath $fullDestinationPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-InstallerPackageProperty {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Package -is [Collections.IDictionary]) {
        if ($Package.Contains($Name)) { return $Package[$Name] }
        return $null
    }

    $property = $Package.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RemoteDocumentRegexMatch {
    [CmdletBinding()]
    [OutputType([Text.RegularExpressions.Match[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DocumentText,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Text.RegularExpressions.RegexOptions]$Options = [Text.RegularExpressions.RegexOptions]::None
    )

    $documentRegex = New-Object Text.RegularExpressions.Regex(
        $Pattern,
        $Options,
        $script:RemoteRegexTimeout
    )
    return @($documentRegex.Matches($DocumentText))
}

function Get-MicrosoftDiscoveryPageUri {
    [CmdletBinding()]
    [OutputType([uri])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    $discoveryType = [string](Get-InstallerPackageProperty -Package $Package -Name 'DiscoveryType')
    switch ($discoveryType) {
        'DownloadCenter' {
            $downloadId = [string](Get-InstallerPackageProperty -Package $Package -Name 'DownloadId')
            if ($downloadId -notmatch '\A[1-9]\d{0,8}\z') {
                throw "Invalid Microsoft Download Center ID: $downloadId"
            }
            $sourceFileName = [string](Get-InstallerPackageProperty -Package $Package -Name 'SourceFileName')
            Assert-InstallerFileName -FileName $sourceFileName
            $pageUri = $script:MicrosoftDownloadCenterUriTemplate -f $downloadId
            return Assert-MicrosoftDiscoveryUri -Uri $pageUri
        }
        'VisualCppDocumentation' {
            $version = [string](Get-InstallerPackageProperty -Package $Package -Name 'Version')
            $architecture = [string](Get-InstallerPackageProperty -Package $Package -Name 'Architecture')
            if ($version -notin @('2008', '2010', '2012')) {
                throw "Unsupported Visual C++ documentation family: $version"
            }
            if ($architecture -notin @('x86', 'x64')) {
                throw "Unsupported Visual C++ documentation architecture: $architecture"
            }
            return Assert-MicrosoftDiscoveryUri -Uri $script:VisualCppDocumentationUri
        }
        default {
            throw "Unsupported Microsoft package discovery type: $discoveryType"
        }
    }
}

function Get-MicrosoftLatestPackageUri {
    [CmdletBinding()]
    [OutputType([uri])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    $discoveryType = [string](Get-InstallerPackageProperty -Package $Package -Name 'DiscoveryType')
    if ($discoveryType -cne 'VisualCppLatestPermalink') {
        throw "Package does not use a Microsoft latest/permanent link: $discoveryType"
    }
    $version = [string](Get-InstallerPackageProperty -Package $Package -Name 'Version')
    $architecture = [string](Get-InstallerPackageProperty -Package $Package -Name 'Architecture')
    if ($architecture -notin @('x86', 'x64')) {
        throw "Unsupported Visual C++ permalink architecture: $architecture"
    }

    $packageUri = if ($version -eq 'v14') {
        'https://aka.ms/vc14/vc_redist.{0}.exe' -f $architecture
    }
    elseif ($version -eq '2013') {
        'https://aka.ms/highdpimfc2013{0}enu' -f $architecture
    }
    else {
        throw "Unsupported Visual C++ permalink family: $version"
    }
    return Assert-MicrosoftUri -Uri $packageUri
}

function Get-VisualCppDocumentationSection {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DocumentText,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $sectionMatches = @(Get-RemoteDocumentRegexMatch -DocumentText $DocumentText -Pattern '(?m)^###[ \t]+(?<title>[^\r\n]+?)[ \t]*\r?$' -Options ([Text.RegularExpressions.RegexOptions]::CultureInvariant))
    $matchingIndexes = @()
    for ($index = 0; $index -lt $sectionMatches.Count; $index++) {
        $title = $sectionMatches[$index].Groups['title'].Value
        $isTarget = if ($Version -eq 'v14') {
            $title -ceq 'Latest supported redistributable version'
        }
        else {
            $title -match ('\AVisual Studio[ \t]+' + [regex]::Escape($Version) + '\b')
        }
        if ($isTarget) { $matchingIndexes += $index }
    }

    if ($matchingIndexes.Count -ne 1) {
        throw "Expected exactly one Visual C++ $Version section in Microsoft documentation; found $($matchingIndexes.Count)."
    }

    $sectionIndex = $matchingIndexes[0]
    $start = $sectionMatches[$sectionIndex].Index
    $end = $DocumentText.Length
    if ($sectionIndex + 1 -lt $sectionMatches.Count) {
        $end = $sectionMatches[$sectionIndex + 1].Index
    }
    return $DocumentText.Substring($start, $end - $start)
}

function Find-MicrosoftPayloadRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DocumentText,

        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    if ([string]::IsNullOrWhiteSpace($DocumentText)) {
        throw 'Microsoft discovery document is empty.'
    }

    $discoveryType = [string](Get-InstallerPackageProperty -Package $Package -Name 'DiscoveryType')
    $packageName = [string](Get-InstallerPackageProperty -Package $Package -Name 'Name')
    $candidateRecords = @()

    if ($discoveryType -eq 'DownloadCenter') {
        $sourceFileName = [string](Get-InstallerPackageProperty -Package $Package -Name 'SourceFileName')
        Assert-InstallerFileName -FileName $sourceFileName
        $pattern = 'https://download\.microsoft\.com/download/(?:[A-Za-z0-9._~%-]+/)+' +
            [regex]::Escape($sourceFileName) + '(?=\z|[\s"''<>\\&])'
        $uriMatches = @(Get-RemoteDocumentRegexMatch -DocumentText $DocumentText -Pattern $pattern -Options ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
        $uniqueUris = @($uriMatches | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Value) } | Sort-Object -Unique)
        foreach ($candidateUri in $uniqueUris) {
            $validatedUri = Assert-MicrosoftUri -Uri $candidateUri
            if (-not [string]::Equals([IO.Path]::GetFileName($validatedUri.AbsolutePath), $sourceFileName, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $candidateRecords += [pscustomobject]@{
                Uri               = $validatedUri.AbsoluteUri
                DocumentedVersion = ''
            }
        }
    }
    elseif ($discoveryType -eq 'VisualCppDocumentation') {
        $version = [string](Get-InstallerPackageProperty -Package $Package -Name 'Version')
        $architecture = [string](Get-InstallerPackageProperty -Package $Package -Name 'Architecture')
        $section = Get-VisualCppDocumentationSection -DocumentText $DocumentText -Version $version

        if ($version -eq 'v14') {
            $pattern = '(?m)^\|[ \t]*' + [regex]::Escape($architecture) +
                '[ \t]*\|[ \t]*(?<url>https://aka\.ms/vc14/vc_redist\.' + [regex]::Escape($architecture) +
                '\.exe)[ \t]*\|[^\r\n]*\r?$'
        }
        else {
            $pattern = '(?m)^\|[ \t]*' + [regex]::Escape($architecture) +
                '[ \t]*\|[ \t]*(?<version>\d{1,5}(?:\.\d{1,5}){3})[ \t]*\|[ \t]*' +
                '\[[^\]\r\n]+\]\((?<url>https://[^)\s]+)\)[ \t]*\|[ \t]*\r?$'
        }

        $rowMatches = @(Get-RemoteDocumentRegexMatch -DocumentText $section -Pattern $pattern -Options ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
        foreach ($rowMatch in $rowMatches) {
            $validatedUri = Assert-MicrosoftUri -Uri $rowMatch.Groups['url'].Value
            if ($version -eq '2013') {
                $expectedPath = '/highdpimfc2013{0}enu' -f $architecture
                if ($validatedUri.AbsolutePath -cne $expectedPath) { continue }
            }
            elseif ($version -ne 'v14') {
                $expectedSourceFileName = 'vcredist_{0}.exe' -f $architecture
                if (-not [string]::Equals([IO.Path]::GetFileName($validatedUri.AbsolutePath), $expectedSourceFileName, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
            }

            $documentedVersion = ''
            if ($version -ne 'v14') {
                $documentedVersion = $rowMatch.Groups['version'].Value
                if ($documentedVersion -notmatch $script:VisualCppFileVersionPattern) {
                    continue
                }
            }
            $candidateRecords += [pscustomobject]@{
                Uri               = $validatedUri.AbsoluteUri
                DocumentedVersion = $documentedVersion
            }
        }
    }
    else {
        throw "Unsupported Microsoft package discovery type: $discoveryType"
    }

    if ($candidateRecords.Count -ne 1) {
        throw "Expected exactly one official Microsoft payload URL for $packageName; found $($candidateRecords.Count)."
    }
    return $candidateRecords[0]
}

function Find-MicrosoftPayloadUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DocumentText,

        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    return [string](Find-MicrosoftPayloadRecord -DocumentText $DocumentText -Package $Package).Uri
}

function Get-MicrosoftDiscoveryDocument {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    $pageUri = Get-MicrosoftDiscoveryPageUri -Package $Package
    if ($Cache.ContainsKey($pageUri.AbsoluteUri)) {
        return [string]$Cache[$pageUri.AbsoluteUri]
    }

    $discoveryDirectory = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) 'discovery'
    if (-not (Test-Path -LiteralPath $discoveryDirectory -PathType Container)) {
        $null = New-Item -Path $discoveryDirectory -ItemType Directory -ErrorAction Stop
    }
    # A cache is scoped to one resolver call, while the protected workspace is
    # shared by every selected component. Use a per-download name so separate
    # resolver calls cannot allocate the same destination inside that workspace.
    $destinationPath = Join-Path $discoveryDirectory ('source-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $download = Invoke-CurlDownload -Uri $pageUri.AbsoluteUri -DestinationPath $destinationPath -DisplayName 'Microsoft package catalog' -ShowProgress $false -UriPurpose Discovery
    if ($download.Length -gt $script:MaximumDiscoveryDocumentBytes) {
        throw "Microsoft discovery document exceeds the $($script:MaximumDiscoveryDocumentBytes)-byte safety limit."
    }

    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $documentText = [IO.File]::ReadAllText($download.Path, $strictUtf8)
    if ([string]::IsNullOrWhiteSpace($documentText)) {
        throw 'Microsoft discovery document is empty.'
    }
    $Cache[$pageUri.AbsoluteUri] = $documentText
    return $documentText
}

function Resolve-MicrosoftPackageSource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    $discoveryType = [string](Get-InstallerPackageProperty -Package $Package -Name 'DiscoveryType')
    $pageUriText = ''
    if ($discoveryType -eq 'VisualCppLatestPermalink') {
        $latestPackageUri = Get-MicrosoftLatestPackageUri -Package $Package
        $source = [pscustomobject]@{
            Uri               = $latestPackageUri.AbsoluteUri
            DocumentedVersion = ''
        }
    }
    else {
        $pageUri = Get-MicrosoftDiscoveryPageUri -Package $Package
        $pageUriText = $pageUri.AbsoluteUri
        $documentText = Get-MicrosoftDiscoveryDocument -Package $Package -WorkspacePath $WorkspacePath -Cache $Cache
        $source = Find-MicrosoftPayloadRecord -DocumentText $documentText -Package $Package
    }

    $resolvedProperties = [ordered]@{}
    foreach ($property in $Package.PSObject.Properties) {
        $resolvedProperties[$property.Name] = $property.Value
    }
    $resolvedProperties['Uri'] = $source.Uri
    $resolvedProperties['DocumentedVersion'] = $source.DocumentedVersion
    $resolvedProperties['DiscoveryPageUri'] = $pageUriText

    $resolvedPackage = [pscustomobject]$resolvedProperties
    Write-InstallerStatus -State Verify -Message ("Official source resolved: {0} | {1}" -f $resolvedPackage.Name, ([uri]$resolvedPackage.Uri).DnsSafeHost)
    return $resolvedPackage
}

function Resolve-MicrosoftPackageSourceSet {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    $cache = @{}
    $resolvedPackages = foreach ($package in $Packages) {
        Resolve-MicrosoftPackageSource -Package $package -WorkspacePath $WorkspacePath -Cache $cache
    }
    return @($resolvedPackages)
}

function Assert-FileSha512 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash
    )

    Assert-Sha512 -Hash $ExpectedHash
    $actualHash = (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA512 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-512 mismatch for $LiteralPath."
    }
    Write-InstallerStatus -State Verify -Message ("SHA-512 verified: {0}" -f [IO.Path]::GetFileName($LiteralPath))
}

function Assert-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash
    )

    Assert-Sha256 -Hash $ExpectedHash
    $actualHash = (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-256 mismatch for $LiteralPath."
    }
    Write-InstallerStatus -State Verify -Message ("SHA-256 verified: {0}" -f [IO.Path]::GetFileName($LiteralPath))
}

function Confirm-DownloadedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Verification
    )

    try {
        & $Verification
    }
    catch {
        $verificationError = $_
        # Never retain or later mistake a failed trust-boundary artifact for a
        # verified package, even when the user requested -KeepDownloads.
        try {
            Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        }
        catch {
            throw "Package verification failed and the untrusted file could not be removed: $($_.Exception.Message)"
        }
        throw $verificationError
    }
}

function ConvertFrom-WindowsMachineType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [uint16]$MachineType
    )

    switch ($MachineType) {
        0x014c { return 'x86' }
        0x8664 { return 'x64' }
        0xAA64 { return 'arm64' }
        0x01c4 { throw '32-bit Windows on ARM is not supported.' }
        default { throw ('Unsupported native Windows machine type: 0x{0:X4}' -f $MachineType) }
    }
}

function Get-NativeWindowsArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $nativeMethods = 'MsftRuntimeInstaller.NativeArchitecture' -as [type]
    if ($null -eq $nativeMethods) {
        $nativeMethods = Add-Type -Namespace MsftRuntimeInstaller -Name NativeArchitecture -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool IsWow64Process2(
    System.IntPtr processHandle,
    out System.UInt16 processMachine,
    out System.UInt16 nativeMachine);
'@ -PassThru -ErrorAction Stop
    }

    [uint16]$processMachine = 0
    [uint16]$nativeMachine = 0
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        try {
            $succeeded = $nativeMethods::IsWow64Process2(
                $currentProcess.Handle,
                [ref]$processMachine,
                [ref]$nativeMachine
            )
        }
        catch {
            $underlyingException = $_.Exception
            if ($null -ne $underlyingException.InnerException) {
                $underlyingException = $underlyingException.InnerException
            }
            if ($underlyingException -is [EntryPointNotFoundException]) {
                # Windows versions before 10 1709 do not expose this API. Their
                # environment and RuntimeInformation values are used below.
                return $null
            }
            throw
        }

        if (-not $succeeded) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "IsWow64Process2 failed with Win32 error $lastError."
        }
    }
    finally {
        $currentProcess.Dispose()
    }

    return ConvertFrom-WindowsMachineType -MachineType $nativeMachine
}

function Get-TargetArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Nullable[bool]]$Is64BitOperatingSystem = $null,

        [ValidateSet('', 'X86', 'X64', 'Arm', 'Arm64')]
        [string]$OperatingSystemArchitecture = ''
    )

    if ($PSBoundParameters.ContainsKey('OperatingSystemArchitecture')) {
        switch ($OperatingSystemArchitecture.ToUpperInvariant()) {
            'X86' { return 'x86' }
            'X64' { return 'x64' }
            'ARM64' { return 'arm64' }
            'ARM' { throw '32-bit Windows on ARM is not supported.' }
        }
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $nativeArchitecture = Get-NativeWindowsArchitecture
        if (-not [string]::IsNullOrWhiteSpace($nativeArchitecture)) {
            return $nativeArchitecture
        }

        $environmentArchitecture = [string]$env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($environmentArchitecture)) {
            $environmentArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
        }
        switch ($environmentArchitecture.ToUpperInvariant()) {
            'X86' { return 'x86' }
            'AMD64' { return 'x64' }
            'ARM64' { return 'arm64' }
            'ARM' { throw '32-bit Windows on ARM is not supported.' }
        }
    }

    $reportedArchitecture = ''
    try {
        $reportedArchitecture = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    }
    catch {
        $reportedArchitecture = ''
    }

    switch ($reportedArchitecture.ToUpperInvariant()) {
        'X86' { return 'x86' }
        'X64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'ARM' { throw '32-bit Windows on ARM is not supported.' }
    }

    if ($PSBoundParameters.ContainsKey('Is64BitOperatingSystem')) {
        if (-not [bool]$Is64BitOperatingSystem) { return 'x86' }
        throw 'Unable to distinguish an unknown 64-bit Windows architecture from ARM64.'
    }

    if ([Environment]::Is64BitOperatingSystem) {
        throw 'Unable to determine the native 64-bit Windows architecture safely.'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return 'x86'
    }

    throw "Unsupported operating-system architecture: $reportedArchitecture"
}

function Get-InstallerResult {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [ValidateSet('DotNet', 'VisualCpp', 'DirectX', 'Extractor')]
        [string]$InstallerType
    )

    if ($ExitCode -eq 0) { return 'Success' }

    switch ($InstallerType) {
        'DotNet' {
            if ($ExitCode -eq 3010) { return 'RestartRequired' }
        }
        'VisualCpp' {
            if ($ExitCode -eq 1638) { return 'AlreadyInstalled' }
            if ($ExitCode -eq 3010) { return 'RestartRequired' }
        }
        'DirectX' {
            if ($ExitCode -eq 3010) { return 'RestartRequired' }
        }
    }

    return 'Failure'
}

function Get-SupportedDotNetChannel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Index,

        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    $indexProperty = $Index.PSObject.Properties['releases-index']
    if ($null -eq $indexProperty) {
        throw '.NET releases index is missing the releases-index property.'
    }

    $supportedChannels = @()
    foreach ($entry in @($indexProperty.Value)) {
        $supportPhase = ([string]$entry.'support-phase').ToLowerInvariant()
        $releaseType = ([string]$entry.'release-type').ToLowerInvariant()

        if ($supportPhase -notmatch $script:DotNetSupportPhasePattern) { continue }
        if ($releaseType -notmatch $script:DotNetReleaseTypePattern) { continue }

        $channelVersion = [string]$entry.'channel-version'
        $latestRelease = [string]$entry.'latest-release'
        $latestSdk = [string]$entry.'latest-sdk'
        if (-not (Test-StableVersion -Version $channelVersion -Channel)) { continue }
        if (-not (Test-StableVersion -Version $latestRelease)) { continue }
        if (-not (Test-StableDotNetSdkVersion -Version $latestSdk)) { continue }

        $eolProperty = $entry.PSObject.Properties['eol-date']
        if ($null -eq $eolProperty) { continue }
        $eolText = [string]$eolProperty.Value
        if ([string]::IsNullOrWhiteSpace($eolText)) { continue }

        $eolDate = [datetime]::ParseExact(
            $eolText,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
        if ($eolDate.Date -lt $AsOfUtc.ToUniversalTime().Date) { continue }

        $releasesJson = [string]$entry.'releases.json'
        $validatedReleasesUri = Assert-MicrosoftUri -Uri $releasesJson
        $supportedChannels += [pscustomobject]@{
            ChannelVersion = $channelVersion
            LatestRelease  = $latestRelease
            LatestSdk      = $latestSdk
            SupportPhase   = $supportPhase
            ReleaseType    = $releaseType
            EolDate        = $eolDate.Date
            ReleasesJson   = $validatedReleasesUri.AbsoluteUri
        }
    }

    return $supportedChannels | Sort-Object -Property @{ Expression = { [version]$_.ChannelVersion }; Ascending = $true }
}

function Resolve-DotNetSdkPackage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$ReleaseMetadata,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,

        [string]$SdkVersion = ''
    )

    $latestSdk = $SdkVersion
    if ([string]::IsNullOrWhiteSpace($latestSdk)) {
        $latestSdk = [string]$ReleaseMetadata.'latest-sdk'
    }
    $channelVersion = [string]$ReleaseMetadata.'channel-version'
    if (-not (Test-StableDotNetSdkVersion -Version $latestSdk)) {
        throw "Invalid or prerelease latest SDK version: $latestSdk"
    }
    if (-not (Test-StableVersion -Version $channelVersion -Channel)) {
        throw "Invalid channel version: $channelVersion"
    }

    $sdkMatches = @()
    foreach ($release in @($ReleaseMetadata.releases)) {
        foreach ($sdk in @($release.sdks)) {
            if ([string]$sdk.version -ceq $latestSdk) {
                $sdkMatches += $sdk
            }
        }
    }
    if ($sdkMatches.Count -ne 1) {
        throw "Expected exactly one SDK metadata record for $latestSdk; found $($sdkMatches.Count)."
    }

    $targetRid = "win-$Architecture"
    $fileMatches = @($sdkMatches[0].files | Where-Object {
        [string]$_.rid -ceq $targetRid -and [string]$_.url -match '\.exe\z'
    })
    if ($fileMatches.Count -ne 1) {
        throw "Expected exactly one $targetRid EXE for SDK $latestSdk; found $($fileMatches.Count)."
    }

    $file = $fileMatches[0]
    $validatedUri = Assert-MicrosoftUri -Uri ([string]$file.url)
    $fileName = [IO.Path]::GetFileName($validatedUri.AbsolutePath)
    Assert-InstallerFileName -FileName $fileName

    $expectedNamePattern = '\Adotnet-sdk-{0}-win-{1}\.exe\z' -f [regex]::Escape($latestSdk), [regex]::Escape($Architecture)
    if ($fileName -notmatch $expectedNamePattern) {
        throw "SDK URL filename does not match resolved version and architecture: $fileName"
    }

    $hash = [string]$file.hash
    Assert-Sha512 -Hash $hash

    return [pscustomobject]@{
        Name         = "Microsoft .NET SDK $latestSdk ($Architecture)"
        Channel      = $channelVersion
        Version      = $latestSdk
        Architecture = $Architecture
        Uri          = $validatedUri.AbsoluteUri
        FileName     = $fileName
        Sha512       = $hash.ToLowerInvariant()
        Arguments    = @('/install', '/passive', '/norestart')
    }
}

function Get-DotNetLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Channel,

        [Parameter(Mandatory = $true)]
        [string]$MetadataDirectory
    )

    if (-not (Test-StableVersion -Version $Channel -Channel)) {
        throw "Invalid stable .NET channel: $Channel"
    }

    $fullMetadataDirectory = [IO.Path]::GetFullPath($MetadataDirectory)
    if (-not (Test-Path -LiteralPath $fullMetadataDirectory -PathType Container)) {
        throw "The .NET metadata directory does not exist: $fullMetadataDirectory"
    }

    $latestVersionPath = Join-Path $fullMetadataDirectory ('latest-{0}.version' -f $Channel)
    $latestVersionUri = $script:DotNetLatestVersionUriTemplate -f $Channel
    $null = Invoke-CurlDownload -Uri $latestVersionUri -DestinationPath $latestVersionPath -DisplayName ('.NET {0} latest stable version' -f $Channel) -ShowProgress $false
    $versionText = Get-Content -LiteralPath $latestVersionPath -Raw -ErrorAction Stop
    return ConvertFrom-DotNetLatestVersionText -VersionText $versionText
}

function Get-DotNetSdkPackage {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,

        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    $metadataDirectory = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) 'metadata'
    if (-not (Test-Path -LiteralPath $metadataDirectory)) {
        $null = New-Item -Path $metadataDirectory -ItemType Directory -Force -ErrorAction Stop
    }

    $indexPath = Join-Path $metadataDirectory 'releases-index.json'
    $null = Invoke-CurlDownload -Uri $script:DotNetReleasesIndexUri -DestinationPath $indexPath -DisplayName '.NET releases index' -ShowProgress $false
    $index = Get-Content -LiteralPath $indexPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $channels = @(Get-SupportedDotNetChannel -Index $index -AsOfUtc $AsOfUtc)
    if ($channels.Count -eq 0) {
        throw 'Microsoft metadata did not contain any supported stable .NET channels.'
    }

    $packages = @()
    foreach ($channel in $channels) {
        $latestEndpointVersion = ''
        try {
            $latestEndpointVersion = Get-DotNetLatestVersion -Channel $channel.ChannelVersion -MetadataDirectory $metadataDirectory
        }
        catch {
            Write-InstallerStatus -State Info -Message (".NET {0} latest.version corroboration was unavailable: {1}. Continuing with Microsoft release metadata and SHA-512 verification." -f $channel.ChannelVersion, $_.Exception.Message)
        }

        $metadataName = 'releases-{0}.json' -f $channel.ChannelVersion
        $releasePath = Join-Path $metadataDirectory $metadataName
        $null = Invoke-CurlDownload -Uri $channel.ReleasesJson -DestinationPath $releasePath -DisplayName ('.NET {0} release metadata' -f $channel.ChannelVersion) -ShowProgress $false
        $releaseMetadata = Get-Content -LiteralPath $releasePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        if ([string]$releaseMetadata.'channel-version' -cne $channel.ChannelVersion) {
            throw "Channel metadata mismatch for $($channel.ChannelVersion)."
        }
        if ([string]$releaseMetadata.'latest-release' -cne $channel.LatestRelease) {
            Write-InstallerStatus -State Info -Message ("Microsoft release metadata differs temporarily for .NET {0}: index {1}, channel metadata {2}." -f $channel.ChannelVersion, $channel.LatestRelease, [string]$releaseMetadata.'latest-release')
        }
        if ([string]$releaseMetadata.'latest-sdk' -cne $channel.LatestSdk) {
            Write-InstallerStatus -State Info -Message ("Microsoft SDK metadata differs temporarily for .NET {0}: index {1}, channel metadata {2}." -f $channel.ChannelVersion, $channel.LatestSdk, [string]$releaseMetadata.'latest-sdk')
        }

        $selectedSdkVersion = [string]$releaseMetadata.'latest-sdk'
        if (-not [string]::IsNullOrWhiteSpace($latestEndpointVersion) -and $latestEndpointVersion -cne $selectedSdkVersion) {
            $endpointMatches = @()
            foreach ($release in @($releaseMetadata.releases)) {
                foreach ($sdk in @($release.sdks)) {
                    if ([string]$sdk.version -ceq $latestEndpointVersion) {
                        $endpointMatches += $sdk
                    }
                }
            }
            if ($endpointMatches.Count -eq 1) {
                $selectedSdkVersion = $latestEndpointVersion
                Write-InstallerStatus -State Info -Message ("Using .NET {0} SDK {1} from Microsoft's latest.version endpoint; its installer is present in SHA-512-bearing release metadata." -f $channel.ChannelVersion, $latestEndpointVersion)
            }
            elseif ($endpointMatches.Count -eq 0) {
                Write-InstallerStatus -State Info -Message ("Microsoft's .NET {0} latest.version endpoint reports {1}, but SHA-512-bearing release metadata does not yet list it. Using verified SDK {2}." -f $channel.ChannelVersion, $latestEndpointVersion, $selectedSdkVersion)
            }
            else {
                throw "Microsoft metadata contains duplicate SDK records for latest.version value $latestEndpointVersion."
            }
        }

        $packages += Resolve-DotNetSdkPackage -ReleaseMetadata $releaseMetadata -Architecture $Architecture -SdkVersion $selectedSdkVersion
    }

    return $packages
}

function Receive-DotNetSdkPackage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    Assert-InstallerFileName -FileName ([string]$Package.FileName)
    Assert-Sha512 -Hash ([string]$Package.Sha512)
    $destinationPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) ([string]$Package.FileName)
    $null = Invoke-CurlDownload -Uri ([string]$Package.Uri) -DestinationPath $destinationPath -DisplayName ([string]$Package.Name)
    Confirm-DownloadedPackage -LiteralPath $destinationPath -Verification {
        Assert-FileSha512 -LiteralPath $destinationPath -ExpectedHash ([string]$Package.Sha512)
    }
    return $destinationPath
}

function ConvertTo-CanonicalSelection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues,

        [Parameter(Mandatory = $true)]
        [string]$OptionName,

        [switch]$AllowEmpty,

        [switch]$ExpandAll
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return @() }
        throw "$OptionName cannot be empty."
    }

    $tokens = @($Value.Split(',') | ForEach-Object { $_.Trim() })
    if (@($tokens | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "$OptionName contains an empty comma-delimited value."
    }

    if (@($tokens | Where-Object { $_ -ieq 'All' }).Count -gt 0) {
        if ($tokens.Count -ne 1) {
            throw "$OptionName value All cannot be combined with other values."
        }
        if ($ExpandAll) { return $AllowedValues }
        return @('All')
    }

    $lookup = @{}
    foreach ($allowedValue in $AllowedValues) {
        $lookup[$allowedValue] = $allowedValue
    }

    $requested = @{}
    foreach ($token in $tokens) {
        if (-not $lookup.ContainsKey($token)) {
            throw "Unknown $OptionName value '$token'. Allowed values: $($AllowedValues -join ', '), or All."
        }
        $canonicalValue = [string]$lookup[$token]
        if ($requested.ContainsKey($canonicalValue)) {
            throw "Duplicate $OptionName value: $token"
        }
        $requested[$canonicalValue] = $true
    }

    return @($AllowedValues | Where-Object { $requested.ContainsKey($_) })
}

function Resolve-ComponentSelection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Components = 'All',

        [AllowEmptyString()]
        [string]$ExcludeComponents = ''
    )

    $allowedComponents = @('DotNet', 'VisualCpp', 'DirectX')
    $included = @(ConvertTo-CanonicalSelection -Value $Components -AllowedValues $allowedComponents -OptionName 'component' -ExpandAll)
    $excluded = @(ConvertTo-CanonicalSelection -Value $ExcludeComponents -AllowedValues $allowedComponents -OptionName 'excluded component' -AllowEmpty -ExpandAll)
    $selected = @($allowedComponents | Where-Object { $included -contains $_ -and $excluded -notcontains $_ })
    if ($selected.Count -eq 0) {
        throw 'Component selection is empty after exclusions.'
    }

    return $selected
}

function Resolve-DotNetChannelSelection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$ChannelSelection = 'All'
    )

    if ([string]::IsNullOrWhiteSpace($ChannelSelection)) {
        throw '.NET channel selection cannot be empty.'
    }

    $tokens = @($ChannelSelection.Split(',') | ForEach-Object { $_.Trim() })
    if (@($tokens | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw '.NET channel selection contains an empty comma-delimited value.'
    }
    if (@($tokens | Where-Object { $_ -ieq 'All' }).Count -gt 0) {
        if ($tokens.Count -ne 1) {
            throw '.NET channel value All cannot be combined with other values.'
        }
        return @('All')
    }

    $seen = @{}
    $channels = @()
    foreach ($token in $tokens) {
        if (-not (Test-StableVersion -Version $token -Channel)) {
            throw "Invalid stable .NET channel: $token"
        }
        if ($seen.ContainsKey($token)) {
            throw "Duplicate .NET channel: $token"
        }
        $seen[$token] = $true
        $channels += $token
    }

    return @($channels | Sort-Object -Property { [version]$_ })
}

function Select-DotNetSdkPackage {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$Packages,

        [string]$ChannelSelection = 'All'
    )

    $requestedChannels = @(Resolve-DotNetChannelSelection -ChannelSelection $ChannelSelection)
    $availableChannels = @($Packages | ForEach-Object { [string]$_.Channel } | Select-Object -Unique)
    if ($availableChannels.Count -eq 0) {
        throw 'No supported .NET SDK packages are available for selection.'
    }

    if ($requestedChannels.Count -eq 1 -and $requestedChannels[0] -eq 'All') {
        return $Packages
    }
    foreach ($requestedChannel in $requestedChannels) {
        if ($availableChannels -notcontains $requestedChannel) {
            throw "Requested .NET channel $requestedChannel is not currently supported. Available channels: $($availableChannels -join ', ')."
        }
    }
    return @($Packages | Where-Object { $requestedChannels -contains [string]$_.Channel })
}

function Get-VisualCppPackage {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$OperatingSystemArchitecture,

        [string]$VersionSelection = 'All'
    )

    if (-not $Configuration.ContainsKey('VisualCpp')) {
        throw 'Package configuration is missing VisualCpp entries.'
    }

    $allowedVersions = @('2005', '2008', '2010', '2012', '2013', 'v14')
    $declaredVersions = @($allowedVersions | Where-Object { $Configuration.VisualCpp.Version -contains $_ })
    $selectedVersions = @(ConvertTo-CanonicalSelection -Value $VersionSelection -AllowedValues $declaredVersions -OptionName 'Visual C++ version' -ExpandAll)

    $selectedPackages = @()
    $seenFileNames = @{}
    foreach ($package in @($Configuration.VisualCpp)) {
        $architecture = [string]$package.Architecture
        if ($architecture -notin @('x86', 'x64')) {
            throw "Invalid Visual C++ package architecture: $architecture"
        }

        $version = [string]$package.Version
        if ($version -notin $allowedVersions) {
            throw "Invalid Visual C++ package version: $version"
        }

        $fileName = [string]$package.FileName
        Assert-InstallerFileName -FileName $fileName
        if ($seenFileNames.ContainsKey($fileName)) {
            throw "Duplicate Visual C++ destination filename: $fileName"
        }
        $seenFileNames[$fileName] = $true

        $discoveryType = [string]$package.DiscoveryType
        $discoveryPageUriText = ''
        if ($discoveryType -eq 'VisualCppLatestPermalink') {
            $null = Get-MicrosoftLatestPackageUri -Package $package
        }
        else {
            $discoveryPageUriText = (Get-MicrosoftDiscoveryPageUri -Package $package).AbsoluteUri
        }
        $name = [string]$package.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Visual C++ package $fileName has no display name."
        }

        $arguments = @($package.Arguments)
        if ($arguments.Count -eq 0 -or @($arguments | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "Visual C++ package $fileName has invalid installer arguments."
        }

        $versionPolicy = [string](Get-InstallerPackageProperty -Package $package -Name 'VersionPolicy')
        $sha256 = [string](Get-InstallerPackageProperty -Package $package -Name 'Sha256')
        $minimumVersion = [string](Get-InstallerPackageProperty -Package $package -Name 'MinimumVersion')
        if ($version -eq 'v14') {
            if ($versionPolicy -cne 'Rolling') {
                throw "Visual C++ v14 package $fileName must use the Rolling version policy."
            }
            if (-not [string]::IsNullOrWhiteSpace($sha256)) {
                throw "Visual C++ v14 package $fileName cannot pin a rolling payload hash."
            }
            if ($minimumVersion -notmatch $script:VisualCppV14VersionPattern) {
                throw "Visual C++ v14 package $fileName has an invalid minimum supported version: $minimumVersion"
            }
            $minimumParsedVersion = [version]$minimumVersion
            if ($minimumParsedVersion.Minor -eq 0) {
                throw "Visual C++ v14 package $fileName has an invalid minimum supported version: $minimumVersion"
            }
        }
        else {
            if ($versionPolicy -cne 'Fixed') {
                throw "Final Visual C++ package $fileName must use the Fixed version policy."
            }
            Assert-Sha256 -Hash $sha256
            if (-not [string]::IsNullOrWhiteSpace($minimumVersion)) {
                throw "Final Visual C++ package $fileName cannot define a rolling minimum version."
            }
        }

        if (($OperatingSystemArchitecture -in @('x64', 'arm64') -or $architecture -eq 'x86') -and $selectedVersions -contains $version) {
            $selectedPackages += [pscustomobject]@{
                Name         = $name
                Version      = $version
                Architecture = $architecture
                DiscoveryType = $discoveryType
                DownloadId   = Get-InstallerPackageProperty -Package $package -Name 'DownloadId'
                SourceFileName = [string](Get-InstallerPackageProperty -Package $package -Name 'SourceFileName')
                DiscoveryPageUri = $discoveryPageUriText
                VersionPolicy = $versionPolicy
                Sha256       = $sha256.ToLowerInvariant()
                MinimumVersion = $minimumVersion
                FileName     = $fileName
                Arguments    = $arguments
            }
        }
    }

    return $selectedPackages
}

function Get-DirectXPackage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration
    )

    if (-not $Configuration.ContainsKey('DirectX')) {
        throw 'Package configuration is missing the DirectX entry.'
    }

    $package = $Configuration.DirectX
    $name = [string]$package.Name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'The DirectX package has no display name.'
    }
    $fileName = [string]$package.FileName
    $setupName = [string]$package.SetupName
    Assert-InstallerFileName -FileName $fileName
    Assert-InstallerFileName -FileName $setupName
    $discoveryPageUri = Get-MicrosoftDiscoveryPageUri -Package $package
    $versionPolicy = [string](Get-InstallerPackageProperty -Package $package -Name 'VersionPolicy')
    if ($versionPolicy -cne 'Fixed') {
        throw 'DirectX June 2010 must use the Fixed version policy.'
    }
    $sha256 = [string](Get-InstallerPackageProperty -Package $package -Name 'Sha256')
    Assert-Sha256 -Hash $sha256

    return [pscustomobject]@{
        Name             = $name
        DiscoveryType    = [string]$package.DiscoveryType
        DownloadId       = Get-InstallerPackageProperty -Package $package -Name 'DownloadId'
        SourceFileName   = [string](Get-InstallerPackageProperty -Package $package -Name 'SourceFileName')
        DiscoveryPageUri = $discoveryPageUri.AbsoluteUri
        VersionPolicy    = $versionPolicy
        Sha256           = $sha256.ToLowerInvariant()
        FileName         = $fileName
        SetupName        = $setupName
    }
}

function Test-MicrosoftSignerSubject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    return $Subject -match '(?:\A|,\s*)O=Microsoft Corporation(?:,|\z)'
}

function Assert-MicrosoftAuthenticodeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $LiteralPath -ErrorAction Stop
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode signature is not valid for $LiteralPath (status: $($signature.Status))."
    }
    if ($null -eq $signature.SignerCertificate -or
        -not (Test-MicrosoftSignerSubject -Subject $signature.SignerCertificate.Subject)) {
        throw "Authenticode signer is not Microsoft Corporation for $LiteralPath."
    }
    Write-InstallerStatus -State Verify -Message ("Microsoft digital signature verified: {0}" -f [IO.Path]::GetFileName($LiteralPath))
}

function Get-VisualCppFileVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath)
    $versionText = '{0}.{1}.{2}.{3}' -f
        $versionInfo.FileMajorPart,
        $versionInfo.FileMinorPart,
        $versionInfo.FileBuildPart,
        $versionInfo.FilePrivatePart

    if ($versionText -ceq '0.0.0.0') {
        $displayVersion = [string]$versionInfo.FileVersion
        if ($displayVersion -match $script:VersionInTextPattern) {
            $versionText = $matches['version']
        }
    }
    if ($versionText -notmatch $script:VisualCppFileVersionPattern) {
        throw "Unexpected Visual C++ file version: $versionText"
    }
    return [version]$versionText
}

function Resolve-VisualCppFileVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    # Do not trust PE metadata until Windows has validated Microsoft's
    # Authenticode signature for the executable.
    Assert-MicrosoftAuthenticodeSignature -LiteralPath $LiteralPath
    return Get-VisualCppFileVersion -LiteralPath $LiteralPath
}

function Assert-VisualCppVersionPolicy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [version]$ActualVersion
    )

    $actualText = $ActualVersion.ToString(4)
    if ([string]$Package.Version -eq 'v14') {
        if ([string]$Package.VersionPolicy -cne 'Rolling') {
            throw 'Visual C++ v14 must use the Rolling version policy.'
        }
        if ($actualText -notmatch $script:VisualCppV14VersionPattern) {
            throw "The current Microsoft v14 permalink returned an unexpected file version: $actualText"
        }
        if ($ActualVersion.Minor -eq 0) {
            throw "The current Microsoft v14 permalink returned the retired 14.0 line: $actualText"
        }
        $minimumVersionText = [string](Get-InstallerPackageProperty -Package $Package -Name 'MinimumVersion')
        if ($minimumVersionText -notmatch $script:VisualCppV14VersionPattern) {
            throw "Visual C++ v14 has an invalid configured security floor: $minimumVersionText"
        }
        $minimumVersion = [version]$minimumVersionText
        if ($minimumVersion.Minor -eq 0) {
            throw "Visual C++ v14 has an invalid configured security floor: $minimumVersionText"
        }
        if ($ActualVersion -lt $minimumVersion) {
            throw "Security check failed: Microsoft v14 returned $actualText, below the reviewed minimum $minimumVersionText."
        }
        return $true
    }

    if ([string]$Package.VersionPolicy -cne 'Fixed') {
        throw "Visual C++ $($Package.Version) must use the Fixed version policy."
    }
    if ($actualText -notmatch $script:VisualCppFileVersionPattern) {
        throw "Visual C++ $($Package.Version) returned an unexpected file version: $actualText"
    }
    $documentedVersion = [string](Get-InstallerPackageProperty -Package $Package -Name 'DocumentedVersion')
    if (-not [string]::IsNullOrWhiteSpace($documentedVersion) -and $actualText -cne $documentedVersion) {
        Write-InstallerStatus -State Info -Message ("Microsoft documentation lists Visual C++ {0} {1} as {2}; the valid signed file reports {3}." -f $Package.Version, $Package.Architecture, $documentedVersion, $actualText)
    }
    return $true
}

function Test-SafeInstallerWorkspacePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [string]$TempPath = [IO.Path]::GetTempPath()
    )

    try {
        $fullWorkspacePath = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $fullTempPath = [IO.Path]::GetFullPath($TempPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $comparison = [StringComparison]::Ordinal
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $comparison = [StringComparison]::OrdinalIgnoreCase
        }

        $parentPath = Split-Path -Parent $fullWorkspacePath
        if (-not [string]::Equals($parentPath, $fullTempPath, $comparison)) { return $false }

        $leafName = Split-Path -Leaf $fullWorkspacePath
        return $leafName -match '\Amsft-runtime-installer-[a-f0-9]{32}\z'
    }
    catch {
        return $false
    }
}

function New-InstallerWorkspace {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param()

    $workspacePath = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-installer-{0}' -f [guid]::NewGuid().ToString('N'))
    if (-not (Test-SafeInstallerWorkspacePath -WorkspacePath $workspacePath)) {
        throw "Generated an unsafe installer workspace path: $workspacePath"
    }

    if (-not $PSCmdlet.ShouldProcess($workspacePath, 'Create installer workspace')) {
        return $null
    }
    $workspace = New-Item -Path $workspacePath -ItemType Directory -ErrorAction Stop
    return $workspace.FullName
}

function Remove-InstallerWorkspace {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    if (-not (Test-SafeInstallerWorkspacePath -WorkspacePath $WorkspacePath)) {
        throw "Refusing to remove an unsafe installer workspace path: $WorkspacePath"
    }
    if (Test-Path -LiteralPath $WorkspacePath) {
        $workspaceItem = Get-Item -LiteralPath $WorkspacePath -Force -ErrorAction Stop
        if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove a reparse-point installer workspace: $WorkspacePath"
        }
        if ($PSCmdlet.ShouldProcess($WorkspacePath, 'Remove installer workspace recursively')) {
            Remove-Item -LiteralPath $WorkspacePath -Recurse -Force -ErrorAction Stop
        }
    }
}

function Invoke-InstallerPackage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [ValidateSet('DotNet', 'VisualCpp', 'DirectX', 'Extractor')]
        [string]$InstallerType
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Installer file does not exist for ${Name}: $LiteralPath"
    }

    Write-InstallerStatus -State Install -Message ("Installing unattended: {0}" -f $Name)
    $installTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Start-Process -FilePath $LiteralPath -ArgumentList $Arguments -Wait -PassThru -ErrorAction Stop
    }
    catch {
        $installTimer.Stop()
        Write-InstallerStatus -State Failed -Message ("{0} could not start: {1}" -f $Name, $_.Exception.Message)
        throw
    }
    $installTimer.Stop()
    $result = Get-InstallerResult -ExitCode $process.ExitCode -InstallerType $InstallerType
    if ($result -eq 'Failure') {
        if ($InstallerType -eq 'VisualCpp' -and $process.ExitCode -eq 1641) {
            Write-InstallerStatus -State Failed -Message ("{0} reported an installer-initiated restart despite the no-restart option." -f $Name)
            throw "$Name breached the no-restart contract with exit code 1641."
        }
        Write-InstallerStatus -State Failed -Message ("Failed: {0} | Exit {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
        throw "$Name failed with exit code $($process.ExitCode)."
    }
    if ($result -eq 'RestartRequired') {
        Write-InstallerStatus -State Restart -Message ("Completed; restart needed: {0} | Exit {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
    }
    elseif ($result -eq 'AlreadyInstalled') {
        Write-InstallerStatus -State Info -Message ("Already current: {0} | Exit {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
    }
    else {
        Write-InstallerStatus -State Ok -Message ("Completed: {0} | Exit {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
    }

    return $result
}

function Receive-SignedMicrosoftPackage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    Assert-InstallerFileName -FileName ([string]$Package.FileName)
    $expectedSha256 = [string](Get-InstallerPackageProperty -Package $Package -Name 'Sha256')
    if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
        Assert-Sha256 -Hash $expectedSha256
    }
    $destinationPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) ([string]$Package.FileName)
    $null = Invoke-CurlDownload -Uri ([string]$Package.Uri) -DestinationPath $destinationPath -DisplayName ([string]$Package.Name)
    Confirm-DownloadedPackage -LiteralPath $destinationPath -Verification {
        if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
            Assert-FileSha256 -LiteralPath $destinationPath -ExpectedHash $expectedSha256
        }
        Assert-MicrosoftAuthenticodeSignature -LiteralPath $destinationPath
    }
    return $destinationPath
}

function Invoke-DotNetSdkInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ref]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ref]$RestartRequired
    )

    for ($packageIndex = 0; $packageIndex -lt $Packages.Count; $packageIndex++) {
        $package = $Packages[$packageIndex]
        Write-InstallerStatus -State Info -Message (".NET package {0} of {1}: {2}" -f ($packageIndex + 1), $Packages.Count, $package.Name)
        $installerPath = Receive-DotNetSdkPackage -Package $package -WorkspacePath $WorkspacePath
        $result = Invoke-InstallerPackage -Name ([string]$package.Name) -LiteralPath $installerPath -Arguments @($package.Arguments) -InstallerType DotNet
        if ($result -eq 'RestartRequired') { $RestartRequired.Value = $true }
        $CompletedPackageCount.Value = [int]$CompletedPackageCount.Value + 1
    }
}

function Invoke-VisualCppInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ref]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ref]$RestartRequired
    )

    for ($packageIndex = 0; $packageIndex -lt $Packages.Count; $packageIndex++) {
        $package = $Packages[$packageIndex]
        Write-InstallerStatus -State Info -Message ("Visual C++ package {0} of {1}: {2}" -f ($packageIndex + 1), $Packages.Count, $package.Name)
        $installerPath = Receive-SignedMicrosoftPackage -Package $package -WorkspacePath $WorkspacePath
        # Receive-SignedMicrosoftPackage verified the signature immediately
        # before this structural PE version read, so avoid a duplicate UI line.
        $fileVersion = Get-VisualCppFileVersion -LiteralPath $installerPath
        $null = Assert-VisualCppVersionPolicy -Package $package -ActualVersion $fileVersion
        Write-InstallerStatus -State Verify -Message ("File version accepted: {0} | {1}" -f $fileVersion.ToString(4), $package.Name)
        $displayName = '{0} [version {1}]' -f $package.Name, $fileVersion.ToString(4)
        $result = Invoke-InstallerPackage -Name $displayName -LiteralPath $installerPath -Arguments @($package.Arguments) -InstallerType VisualCpp
        if ($result -eq 'RestartRequired') { $RestartRequired.Value = $true }
        $CompletedPackageCount.Value = [int]$CompletedPackageCount.Value + 1
    }
}

function Invoke-DirectXInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ref]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ref]$RestartRequired
    )

    $setupName = [string]$Package.SetupName
    Assert-InstallerFileName -FileName $setupName

    Write-InstallerStatus -State Info -Message ("DirectX package 1 of 1: {0}" -f $Package.Name)
    $extractorPath = Receive-SignedMicrosoftPackage -Package $Package -WorkspacePath $WorkspacePath
    $extractionPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) 'directx-extracted'
    $null = New-Item -Path $extractionPath -ItemType Directory -ErrorAction Stop
    $extractResult = Invoke-InstallerPackage -Name "$($Package.Name) extraction" -LiteralPath $extractorPath -Arguments @('/Q', ('/T:"{0}"' -f $extractionPath)) -InstallerType Extractor

    $setupPath = Join-Path $extractionPath $setupName
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "DirectX extraction did not produce $setupName."
    }
    Confirm-DownloadedPackage -LiteralPath $setupPath -Verification {
        Assert-MicrosoftAuthenticodeSignature -LiteralPath $setupPath
    }
    $setupResult = Invoke-InstallerPackage -Name ([string]$Package.Name) -LiteralPath $setupPath -Arguments @('/silent') -InstallerType DirectX

    if ($extractResult -eq 'RestartRequired' -or $setupResult -eq 'RestartRequired') {
        $RestartRequired.Value = $true
    }
    $CompletedPackageCount.Value = [int]$CompletedPackageCount.Value + 1
}

Export-ModuleMember -Function @(
    'Assert-FileSha256',
    'Assert-FileSha512',
    'Assert-InstallerFileName',
    'Assert-MicrosoftDiscoveryUri',
    'Assert-MicrosoftUri',
    'Assert-Sha256',
    'Assert-Sha512',
    'Assert-VisualCppVersionPolicy',
    'Find-MicrosoftPayloadUri',
    'Get-CurlArgument',
    'Get-CurlVersion',
    'Get-DirectXPackage',
    'Get-DotNetLatestVersion',
    'Get-DotNetSdkPackage',
    'Get-InstallerResult',
    'Get-MicrosoftLatestPackageUri',
    'Get-SupportedDotNetChannel',
    'Get-TargetArchitecture',
    'Get-VisualCppPackage',
    'Invoke-DirectXInstallation',
    'Invoke-CurlDownload',
    'Invoke-DotNetSdkInstallation',
    'Invoke-InstallerPackage',
    'Invoke-VisualCppInstallation',
    'New-InstallerWorkspace',
    'Receive-DotNetSdkPackage',
    'Remove-InstallerWorkspace',
    'Resolve-ComponentSelection',
    'Resolve-DotNetChannelSelection',
    'Resolve-DotNetSdkPackage',
    'Resolve-MicrosoftPackageSourceSet',
    'Resolve-VisualCppFileVersion',
    'Select-DotNetSdkPackage',
    'Test-AllowedMicrosoftDiscoveryUri',
    'Test-AllowedMicrosoftUri',
    'Test-MicrosoftSignerSubject',
    'Test-SafeInstallerWorkspacePath',
    'Test-StableDotNetSdkVersion',
    'Test-StableVersion'
    'ConvertFrom-DotNetLatestVersionText'
)
