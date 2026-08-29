@{
    VisualCpp = @(
        @{
            Name         = 'Microsoft Visual C++ 2005 SP1 Redistributable (x86)'
            Version      = '2005'
            Architecture = 'x86'
            Uri          = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE'
            FileName     = 'vcredist-2005-x86.exe'
            Arguments    = @('/q')
        }
        @{
            Name         = 'Microsoft Visual C++ 2005 SP1 Redistributable (x64)'
            Version      = '2005'
            Architecture = 'x64'
            Uri          = 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE'
            FileName     = 'vcredist-2005-x64.exe'
            Arguments    = @('/q')
        }
        @{
            Name         = 'Microsoft Visual C++ 2008 SP1 Redistributable (x86)'
            Version      = '2008'
            Architecture = 'x86'
            Uri          = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'
            FileName     = 'vcredist-2008-x86.exe'
            Arguments    = @('/q', '/r:n')
        }
        @{
            Name         = 'Microsoft Visual C++ 2008 SP1 Redistributable (x64)'
            Version      = '2008'
            Architecture = 'x64'
            Uri          = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'
            FileName     = 'vcredist-2008-x64.exe'
            Arguments    = @('/q', '/r:n')
        }
        @{
            Name         = 'Microsoft Visual C++ 2010 SP1 Redistributable (x86)'
            Version      = '2010'
            Architecture = 'x86'
            Uri          = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'
            FileName     = 'vcredist-2010-x86.exe'
            Arguments    = @('/passive', '/norestart')
        }
        @{
            Name         = 'Microsoft Visual C++ 2010 SP1 Redistributable (x64)'
            Version      = '2010'
            Architecture = 'x64'
            Uri          = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'
            FileName     = 'vcredist-2010-x64.exe'
            Arguments    = @('/passive', '/norestart')
        }
        @{
            Name         = 'Microsoft Visual C++ 2012 Update 4 Redistributable (x86)'
            Version      = '2012'
            Architecture = 'x86'
            Uri          = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'
            FileName     = 'vcredist-2012-x86.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
        @{
            Name         = 'Microsoft Visual C++ 2012 Update 4 Redistributable (x64)'
            Version      = '2012'
            Architecture = 'x64'
            Uri          = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'
            FileName     = 'vcredist-2012-x64.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
        @{
            Name         = 'Microsoft Visual C++ 2013 Redistributable (x86)'
            Version      = '2013'
            Architecture = 'x86'
            Uri          = 'https://aka.ms/highdpimfc2013x86enu'
            FileName     = 'vcredist-2013-x86.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
        @{
            Name         = 'Microsoft Visual C++ 2013 Redistributable (x64)'
            Version      = '2013'
            Architecture = 'x64'
            Uri          = 'https://aka.ms/highdpimfc2013x64enu'
            FileName     = 'vcredist-2013-x64.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
        @{
            Name         = 'Latest supported Microsoft Visual C++ v14 Redistributable (x86)'
            Version      = 'v14'
            Architecture = 'x86'
            Uri          = 'https://aka.ms/vc14/vc_redist.x86.exe'
            FileName     = 'vc-redist-v14-x86.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
        @{
            Name         = 'Latest supported Microsoft Visual C++ v14 Redistributable (x64)'
            Version      = 'v14'
            Architecture = 'x64'
            Uri          = 'https://aka.ms/vc14/vc_redist.x64.exe'
            FileName     = 'vc-redist-v14-x64.exe'
            Arguments    = @('/install', '/passive', '/norestart')
        }
    )

    DirectX = @{
        Name      = 'Microsoft DirectX End-User Runtimes (June 2010)'
        Uri       = 'https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe'
        FileName  = 'directx_Jun2010_redist.exe'
        SetupName = 'DXSETUP.exe'
    }
}
