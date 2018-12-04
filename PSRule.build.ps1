
param (
    [Parameter(Mandatory = $False)]
    [String]$ModuleVersion,

    [Parameter(Mandatory = $False)]
    [String]$Configuration = 'Debug',

    [Parameter(Mandatory = $False)]
    [String]$NuGetApiKey,

    [Parameter(Mandatory = $False)]
    [Switch]$CodeCoverage = $False,

    [String]$ArtifactPath = (Join-Path -Path $PWD -ChildPath out/modules)
)

# Copy the PowerShell modules files to the destination path
function CopyModuleFiles {

    param (
        [Parameter(Mandatory = $True)]
        [String]$Path,

        [Parameter(Mandatory = $True)]
        [String]$DestinationPath
    )

    process {
        $sourcePath = Resolve-Path -Path $Path;

        Get-ChildItem -Path $sourcePath -Recurse -File -Include *.ps1,*.psm1,*.psd1,*.ps1xml | Where-Object -FilterScript {
            ($_.FullName -notmatch '(\.(cs|csproj)|(\\|\/)(obj|bin))')
        } | ForEach-Object -Process {
            $filePath = $_.FullName.Replace($sourcePath, $destinationPath);

            $parentPath = Split-Path -Path $filePath -Parent;

            if (!(Test-Path -Path $parentPath)) {
                $Null = New-Item -Path $parentPath -ItemType Directory -Force;
            }

            Copy-Item -Path $_.FullName -Destination $filePath -Force;
        };
    }
}

function SendAppveyorTestResult {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [String]$Uri,

        [Parameter(Mandatory = $True)]
        [String]$Path,

        [Parameter(Mandatory = $False)]
        [String]$Include = '*'
    )

    begin {
        Write-Verbose -Message "[SendAppveyorTestResult] BEGIN::";
    }

    process {

        try {
            $webClient = New-Object -TypeName 'System.Net.WebClient';

            foreach ($resultFile in (Get-ChildItem -Path $Path -Filter $Include -File -Recurse)) {

                Write-Verbose -Message "[SendAppveyorTestResult] -- Uploading file: $($resultFile.FullName)";

                $webClient.UploadFile($Uri, "$($resultFile.FullName)");
            }
        }
        catch {
            throw $_.Exception;
        }
        finally {
            $webClient = $Null;
        }
    }

    end {
        Write-Verbose -Message "[SendAppveyorTestResult] END::";
    }
}

task BuildDotNet {
    exec {
        # Build library
        dotnet publish src/PSRule -c $Configuration -f netstandard2.0 -o $(Join-Path -Path $PWD -ChildPath out/modules/PSRule/core)
    }
}

task CopyModule {
    CopyModuleFiles -Path src/PSRule -DestinationPath out/modules/PSRule;

    # Copy third party notices
    Copy-Item -Path ThirdPartyNotices.txt -Destination out/modules/PSRule;
}

# Synopsis: Build modules only
task BuildModule BuildDotNet, CopyModule

# Synopsis: Build help
task BuildHelp BuildModule, PlatyPS, {

    # Generate MAML and about topics
    $Null = New-ExternalHelp -OutputPath out/docs/PSRule -Path '.\docs\commands\PSRule\en-US','.\docs\keywords\PSRule\en-US' -Force;

    # Copy generated help into module out path
    $Null = Copy-Item -Path out/docs/PSRule/* -Destination out/modules/PSRule/en-US;
    $Null = Copy-Item -Path out/docs/PSRule/* -Destination out/modules/PSRule/en-AU;
}

task ScaffoldHelp BuildModule, {

    Import-Module (Join-Path -Path $PWD -ChildPath out/modules/PSRule) -Force;

    Update-MarkdownHelp -Path '.\docs\commands\PSRule\en-US';
}

# Synopsis: Remove temp files.
task Clean {
    Remove-Item -Path out,reports -Recurse -Force -ErrorAction SilentlyContinue;
}

task VersionModule {

    if (![String]::IsNullOrEmpty($ModuleVersion)) {

        $version = $ModuleVersion;
        $revision = [String]::Empty;

        if ($version -like '*-*') {
            [String[]]$versionParts = $version.Split('-', [System.StringSplitOptions]::RemoveEmptyEntries);
            $version = $versionParts[0];

            if ($versionParts.Length -eq 2) {
                $revision = $versionParts[1];
            }
        }

        # Update module version
        if (![String]::IsNullOrEmpty($version)) {
            Update-ModuleManifest -Path (Join-Path -Path $ArtifactPath -ChildPath PSRule/PSRule.psd1) -ModuleVersion $version;
        }

        # Update pre-release version
        if (![String]::IsNullOrEmpty($revision)) {
            Update-ModuleManifest -Path (Join-Path -Path $ArtifactPath -ChildPath PSRule/PSRule.psd1) -Prerelease $revision;
        }
    }
}

task ReleaseModule VersionModule, {

    if ($Null -ne 'NuGetApiKey') {
        # Publish to PowerShell Gallery
        Publish-Module -Path (Join-Path -Path $ArtifactPath -ChildPath PSRule) -NuGetApiKey $NuGetApiKey;
    }
}

task NuGet {
    $Null = Install-PackageProvider -Name NuGet -Force -Scope CurrentUser;
}

task Pester {

    # Install pester if v4+ is not currently installed
    if ($Null -eq (Get-Module -Name Pester -ListAvailable | Where-Object -FilterScript { $_.Version -like '4.*' })) {
        Install-Module -Name Pester -MinimumVersion '4.0.0' -Force -Scope CurrentUser -SkipPublisherCheck;
    }

    Import-Module -Name Pester -Verbose:$False;
}

task platyPS {

    # Install pester if v4+ is not currently installed
    if ($Null -eq (Get-Module -Name PlatyPS -ListAvailable)) {
        Install-Module -Name PlatyPS -Force -Scope CurrentUser;
    }

    Import-Module -Name PlatyPS -Verbose:$False;
}

task PSScriptAnalyzer {

    # Install PSScriptAnalyzer if not currently installed
    if ($Null -eq (Get-Module -Name PSScriptAnalyzer -ListAvailable)) {
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser;
    }

    Import-Module -Name PSScriptAnalyzer -Verbose:$False;
}

task TestModule Pester, PSScriptAnalyzer, {

    # Run Pester tests
    $pesterParams = @{ Path = $PWD; OutputFile = 'reports/Pester.xml'; OutputFormat = 'NUnitXml'; PesterOption = @{ IncludeVSCodeMarker = $True }; PassThru = $True; };

    if ($CodeCoverage) {
        $pesterParams.Add('CodeCoverage', (Join-Path -Path $PWD -ChildPath 'out/modules/**/*.psm1'));
    }

    if (!(Test-Path -Path reports)) {
        $Null = New-Item -Path reports -ItemType Directory -Force;
    }

    $results = Invoke-Pester @pesterParams;

    if (![String]::IsNullOrEmpty($Env:APPVEYOR_JOB_ID)) {
        SendAppveyorTestResult -Uri "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)" -Path '.\reports' -Include '*.xml';
    }

    # Throw an error if pester tests failed

    if ($Null -eq $results) {
        throw 'Failed to get Pester test results.';
    }
    elseif ($results.FailedCount -gt 0) {
        throw "$($results.FailedCount) tests failed.";
    }
}

# Synopsis: Run script analyzer
task Analyze Build, PSScriptAnalyzer, {

    Invoke-ScriptAnalyzer -Path out/modules/PSRule;
}

# Synopsis: Build and clean.
task . Build, Test

# Synopsis: Build the project
task Build Clean, BuildModule, BuildHelp, VersionModule

task Test Build, TestModule

task Release ReleaseModule