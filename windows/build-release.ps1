$ErrorActionPreference = "Stop"

$windowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $windowsRoot
$dotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
if (-not (Test-Path -LiteralPath $dotnet)) {
    throw ".NET 8 SDK is required. Install Microsoft.DotNet.SDK.8 first."
}

$buildHome = Join-Path $repositoryRoot ".build-tools"
$env:DOTNET_CLI_HOME = $buildHome
$env:NUGET_PACKAGES = Join-Path $buildHome "nuget"
$env:APPDATA = $buildHome
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"

$solution = Join-Path $windowsRoot "Tvoice.Windows.sln"
$project = Join-Path $windowsRoot "Tvoice.Windows\Tvoice.Windows.csproj"
$tests = Join-Path $windowsRoot "Tvoice.Windows.SmokeTests\Tvoice.Windows.SmokeTests.csproj"
$nugetConfig = Join-Path $windowsRoot "NuGet.Config"
$publishDirectory = Join-Path $windowsRoot "artifacts\Tvoice.Windows-x64"

& $dotnet restore $solution --configfile $nugetConfig
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $dotnet build $solution -c Release --no-restore
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $dotnet run --project $tests -c Release --no-build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $dotnet restore $project -r win-x64 --configfile $nugetConfig
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $publishDirectory --no-restore
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$innoCompiler = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
if (-not (Test-Path -LiteralPath $innoCompiler)) {
    $innoCompiler = Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
}
if (Test-Path -LiteralPath $innoCompiler) {
    $installerScript = Join-Path $windowsRoot "installer\Tvoice.iss"
    & $innoCompiler $installerScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
exit 0
