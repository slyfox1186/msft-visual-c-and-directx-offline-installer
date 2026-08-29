Set-StrictMode -Version 2.0

Import-Module -Name (Join-Path $PSScriptRoot 'ConsoleUI.psm1') -ErrorAction Stop

$script:AllowedMicrosoftHostPattern = '\A(?:aka\.ms|builds\.dotnet\.microsoft\.com|download\.microsoft\.com|download\.visualstudio\.microsoft\.com)\z'
$script:StableChannelPattern = '\A\d+\.\d+\z'
$script:StableVersionPattern = '\A\d+\.\d+\.\d+\z'
$script:Sha512Pattern = '\A[A-Fa-f0-9]{128}\z'
$script:InstallerFileNamePattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.exe\z'
$script:DotNetReleasesIndexUri = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'

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

        [bool]$ShowProgress = $true
    )

    $validatedUri = Assert-MicrosoftUri -Uri $Uri
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

        [bool]$ShowProgress = $true
    )

    $validatedUri = Assert-MicrosoftUri -Uri $Uri
    $fullDestinationPath = [IO.Path]::GetFullPath($DestinationPath)
    $destinationDirectory = Split-Path -Parent $fullDestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        throw "Curl destination directory does not exist: $destinationDirectory"
    }
    if (Test-Path -LiteralPath $fullDestinationPath) {
        throw "Refusing to overwrite an existing download: $fullDestinationPath"
    }

    $curlExecutable = Get-CurlExecutable
    $curlArguments = Get-CurlArgument -Uri $validatedUri.AbsoluteUri -DestinationPath $fullDestinationPath -ShowProgress $ShowProgress
    $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-InstallerStatus -State Download -Message ("{0} from {1}" -f $DisplayName, $validatedUri.DnsSafeHost)

    try {
        $effectiveUriText = (& $curlExecutable @curlArguments | Out-String).Trim()
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            throw "curl.exe failed with exit code $curlExitCode while downloading $($validatedUri.AbsoluteUri)"
        }
        if ([string]::IsNullOrWhiteSpace($effectiveUriText)) {
            throw 'curl.exe did not report an effective URL.'
        }

        $effectiveUri = Assert-MicrosoftUri -Uri $effectiveUriText
        $downloadedFile = Get-Item -LiteralPath $fullDestinationPath -Force -ErrorAction Stop
        if ($downloadedFile.PSIsContainer -or $downloadedFile.Length -le 0) {
            throw "curl.exe did not create a nonempty regular file: $fullDestinationPath"
        }

        $downloadTimer.Stop()
        Write-InstallerStatus -State Ok -Message ("Downloaded {0} | {1} | {2} | {3}" -f $DisplayName, $effectiveUri.DnsSafeHost, (Format-InstallerByteSize -Bytes $downloadedFile.Length), (Format-InstallerDuration -Duration $downloadTimer.Elapsed))

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
    Write-InstallerStatus -State Verify -Message ("SHA-512 matched for {0}" -f [IO.Path]::GetFileName($LiteralPath))
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

        if ($supportPhase -notin @('active', 'maintenance')) { continue }
        if ($releaseType -notin @('lts', 'sts')) { continue }

        $channelVersion = [string]$entry.'channel-version'
        $latestRelease = [string]$entry.'latest-release'
        $latestSdk = [string]$entry.'latest-sdk'
        if (-not (Test-StableVersion -Version $channelVersion -Channel)) { continue }
        if (-not (Test-StableVersion -Version $latestRelease)) { continue }
        if (-not (Test-StableVersion -Version $latestSdk)) { continue }

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
        [string]$Architecture
    )

    $latestSdk = [string]$ReleaseMetadata.'latest-sdk'
    $channelVersion = [string]$ReleaseMetadata.'channel-version'
    if (-not (Test-StableVersion -Version $latestSdk)) {
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
        $metadataName = 'releases-{0}.json' -f $channel.ChannelVersion
        $releasePath = Join-Path $metadataDirectory $metadataName
        $null = Invoke-CurlDownload -Uri $channel.ReleasesJson -DestinationPath $releasePath -DisplayName ('.NET {0} release metadata' -f $channel.ChannelVersion) -ShowProgress $false
        $releaseMetadata = Get-Content -LiteralPath $releasePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        if ([string]$releaseMetadata.'channel-version' -cne $channel.ChannelVersion) {
            throw "Channel metadata mismatch for $($channel.ChannelVersion)."
        }
        if ([string]$releaseMetadata.'latest-release' -cne $channel.LatestRelease) {
            throw "Latest release metadata mismatch for channel $($channel.ChannelVersion)."
        }
        if ([string]$releaseMetadata.'latest-sdk' -cne $channel.LatestSdk) {
            throw "Latest SDK metadata mismatch for channel $($channel.ChannelVersion)."
        }

        $packages += Resolve-DotNetSdkPackage -ReleaseMetadata $releaseMetadata -Architecture $Architecture
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

        $validatedUri = Assert-MicrosoftUri -Uri ([string]$package.Uri)
        $name = [string]$package.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Visual C++ package $fileName has no display name."
        }

        $arguments = @($package.Arguments)
        if ($arguments.Count -eq 0 -or @($arguments | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "Visual C++ package $fileName has invalid installer arguments."
        }

        if (($OperatingSystemArchitecture -in @('x64', 'arm64') -or $architecture -eq 'x86') -and $selectedVersions -contains $version) {
            $selectedPackages += [pscustomobject]@{
                Name         = $name
                Version      = $version
                Architecture = $architecture
                Uri          = $validatedUri.AbsoluteUri
                FileName     = $fileName
                Arguments    = $arguments
            }
        }
    }

    return $selectedPackages
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
    Write-InstallerStatus -State Verify -Message ("Valid Microsoft Authenticode signature: {0}" -f [IO.Path]::GetFileName($LiteralPath))
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

    Write-InstallerStatus -State Install -Message $Name
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
        Write-InstallerStatus -State Failed -Message ("{0} | exit code {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
        throw "$Name failed with exit code $($process.ExitCode)."
    }
    if ($result -eq 'RestartRequired') {
        Write-InstallerStatus -State Restart -Message ("{0} | exit code {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
    }
    elseif ($result -eq 'AlreadyInstalled') {
        Write-InstallerStatus -State Info -Message ("{0} | a newer or equivalent version is already installed | exit code {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
    }
    else {
        Write-InstallerStatus -State Ok -Message ("{0} | exit code {1} | {2}" -f $Name, $process.ExitCode, (Format-InstallerDuration -Duration $installTimer.Elapsed))
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
    $destinationPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) ([string]$Package.FileName)
    $null = Invoke-CurlDownload -Uri ([string]$Package.Uri) -DestinationPath $destinationPath -DisplayName ([string]$Package.Name)
    Confirm-DownloadedPackage -LiteralPath $destinationPath -Verification {
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

    foreach ($package in $Packages) {
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
        [hashtable]$Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$OperatingSystemArchitecture,

        [string]$VersionSelection = 'All',

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ref]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ref]$RestartRequired
    )

    $packages = @(Get-VisualCppPackage -Configuration $Configuration -OperatingSystemArchitecture $OperatingSystemArchitecture -VersionSelection $VersionSelection)
    foreach ($package in $packages) {
        $installerPath = Receive-SignedMicrosoftPackage -Package $package -WorkspacePath $WorkspacePath
        $result = Invoke-InstallerPackage -Name ([string]$package.Name) -LiteralPath $installerPath -Arguments @($package.Arguments) -InstallerType VisualCpp
        if ($result -eq 'RestartRequired') { $RestartRequired.Value = $true }
        $CompletedPackageCount.Value = [int]$CompletedPackageCount.Value + 1
    }
}

function Invoke-DirectXInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [ref]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ref]$RestartRequired
    )

    if (-not $Configuration.ContainsKey('DirectX')) {
        throw 'Package configuration is missing the DirectX entry.'
    }
    $package = $Configuration.DirectX
    $setupName = [string]$package.SetupName
    Assert-InstallerFileName -FileName $setupName

    $extractorPath = Receive-SignedMicrosoftPackage -Package $package -WorkspacePath $WorkspacePath
    $extractionPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) 'directx-extracted'
    $null = New-Item -Path $extractionPath -ItemType Directory -ErrorAction Stop
    $extractResult = Invoke-InstallerPackage -Name "$($package.Name) extraction" -LiteralPath $extractorPath -Arguments @('/Q', ('/T:"{0}"' -f $extractionPath)) -InstallerType Extractor

    $setupPath = Join-Path $extractionPath $setupName
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "DirectX extraction did not produce $setupName."
    }
    Confirm-DownloadedPackage -LiteralPath $setupPath -Verification {
        Assert-MicrosoftAuthenticodeSignature -LiteralPath $setupPath
    }
    $setupResult = Invoke-InstallerPackage -Name ([string]$package.Name) -LiteralPath $setupPath -Arguments @('/silent') -InstallerType DirectX

    if ($extractResult -eq 'RestartRequired' -or $setupResult -eq 'RestartRequired') {
        $RestartRequired.Value = $true
    }
    $CompletedPackageCount.Value = [int]$CompletedPackageCount.Value + 1
}

Export-ModuleMember -Function @(
    'Assert-FileSha512',
    'Assert-InstallerFileName',
    'Assert-MicrosoftUri',
    'Assert-Sha512',
    'Get-CurlArgument',
    'Get-CurlVersion',
    'Get-DotNetSdkPackage',
    'Get-InstallerResult',
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
    'Select-DotNetSdkPackage',
    'Test-AllowedMicrosoftUri',
    'Test-MicrosoftSignerSubject',
    'Test-SafeInstallerWorkspacePath',
    'Test-StableVersion'
)
