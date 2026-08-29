@{
    VisualCpp = @(
        @{
            Name           = 'Microsoft Visual C++ 2005 SP1 Redistributable (x86)'
            Version        = '2005'
            Architecture   = 'x86'
            DiscoveryType  = 'DownloadCenter'
            DownloadId     = 26347
            SourceFileName = 'vcredist_x86.EXE'
            VersionPolicy  = 'Fixed'
            Sha256         = '8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd'
            FileName       = 'vcredist-2005-x86.exe'
            Arguments      = @('/q', '/r:n')
        }
        @{
            Name           = 'Microsoft Visual C++ 2005 SP1 Redistributable (x64)'
            Version        = '2005'
            Architecture   = 'x64'
            DiscoveryType  = 'DownloadCenter'
            DownloadId     = 26347
            SourceFileName = 'vcredist_x64.EXE'
            VersionPolicy  = 'Fixed'
            Sha256         = '4487570bd86e2e1aac29db2a1d0a91eb63361fcaac570808eb327cd4e0e2240d'
            FileName       = 'vcredist-2005-x64.exe'
            Arguments      = @('/q', '/r:n')
        }
        @{
            Name           = 'Microsoft Visual C++ 2008 SP1 Redistributable (x86)'
            Version        = '2008'
            Architecture   = 'x86'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = '8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92'
            FileName       = 'vcredist-2008-x86.exe'
            Arguments      = @('/q', '/r:n')
        }
        @{
            Name           = 'Microsoft Visual C++ 2008 SP1 Redistributable (x64)'
            Version        = '2008'
            Architecture   = 'x64'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = 'c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654'
            FileName       = 'vcredist-2008-x64.exe'
            Arguments      = @('/q', '/r:n')
        }
        @{
            Name           = 'Microsoft Visual C++ 2010 SP1 Redistributable (x86)'
            Version        = '2010'
            Architecture   = 'x86'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = '99dce3c841cc6028560830f7866c9ce2928c98cf3256892ef8e6cf755147b0d8'
            FileName       = 'vcredist-2010-x86.exe'
            Arguments      = @('/passive', '/norestart')
        }
        @{
            Name           = 'Microsoft Visual C++ 2010 SP1 Redistributable (x64)'
            Version        = '2010'
            Architecture   = 'x64'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = 'f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3'
            FileName       = 'vcredist-2010-x64.exe'
            Arguments      = @('/passive', '/norestart')
        }
        @{
            Name           = 'Microsoft Visual C++ 2012 Update 4 Redistributable (x86)'
            Version        = '2012'
            Architecture   = 'x86'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = 'b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386'
            FileName       = 'vcredist-2012-x86.exe'
            Arguments      = @('/install', '/passive', '/norestart')
        }
        @{
            Name           = 'Microsoft Visual C++ 2012 Update 4 Redistributable (x64)'
            Version        = '2012'
            Architecture   = 'x64'
            DiscoveryType  = 'VisualCppDocumentation'
            VersionPolicy  = 'Fixed'
            Sha256         = '681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064'
            FileName       = 'vcredist-2012-x64.exe'
            Arguments      = @('/install', '/passive', '/norestart')
        }
        @{
            Name          = 'Microsoft Visual C++ 2013 Redistributable (x86)'
            Version       = '2013'
            Architecture  = 'x86'
            DiscoveryType = 'VisualCppLatestPermalink'
            VersionPolicy = 'Fixed'
            Sha256        = '53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd'
            FileName      = 'vcredist-2013-x86.exe'
            Arguments     = @('/install', '/passive', '/norestart')
        }
        @{
            Name          = 'Microsoft Visual C++ 2013 Redistributable (x64)'
            Version       = '2013'
            Architecture  = 'x64'
            DiscoveryType = 'VisualCppLatestPermalink'
            VersionPolicy = 'Fixed'
            Sha256        = 'a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c'
            FileName      = 'vcredist-2013-x64.exe'
            Arguments     = @('/install', '/passive', '/norestart')
        }
        @{
            Name          = 'Latest supported Microsoft Visual C++ v14 Redistributable (x86)'
            Version       = 'v14'
            Architecture  = 'x86'
            DiscoveryType = 'VisualCppLatestPermalink'
            VersionPolicy = 'Rolling'
            MinimumVersion = '14.51.36247.0'
            FileName      = 'vc-redist-v14-x86.exe'
            Arguments     = @('/install', '/passive', '/norestart')
        }
        @{
            Name          = 'Latest supported Microsoft Visual C++ v14 Redistributable (x64)'
            Version       = 'v14'
            Architecture  = 'x64'
            DiscoveryType = 'VisualCppLatestPermalink'
            VersionPolicy = 'Rolling'
            MinimumVersion = '14.51.36247.0'
            FileName      = 'vc-redist-v14-x64.exe'
            Arguments     = @('/install', '/passive', '/norestart')
        }
    )

    DirectX = @{
        Name           = 'Microsoft DirectX End-User Runtimes (June 2010)'
        DiscoveryType  = 'DownloadCenter'
        DownloadId     = 8109
        SourceFileName = 'directx_Jun2010_redist.exe'
        VersionPolicy  = 'Fixed'
        Sha256         = '053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b'
        FileName       = 'directx_Jun2010_redist.exe'
        SetupName      = 'DXSETUP.exe'
    }
}
