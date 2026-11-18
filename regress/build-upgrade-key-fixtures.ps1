# Build is the current build's folder (its CMakeCache.txt names the vcpkg packages the
# fixtures share), Conpty a folder holding conpty.dll and OpenConsole.exe; the fixtures
# are built inside Build. CTest runs this before the key upgrade tests (CMakeLists.txt).
param([string]$CMake = 'cmake', [string]$LegacyExecutable, [string]$Build, [string]$Conpty)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Build) { $Build = "$repo/build" }
if (-not $Conpty) { $Conpty = "$Build/upgrade" }
$legacyCommit = '529c862fae20fa4e3c55ad342a4999011ab291cb'
$dependencyCache = Select-String -Path "$Build/CMakeCache.txt" -Pattern '^VCPKG_INSTALLED_DIR:[^=]+=(.+)$'
if (-not $dependencyCache) { throw 'Current build dependency location missing' }
$dependencyInstall = $dependencyCache.Matches[0].Groups[1].Value
# Where vcpkg builds a port, if the current build names one (the cmake suite's short folder).
$installOptions = Select-String -Path "$Build/CMakeCache.txt" -Pattern '^VCPKG_INSTALL_OPTIONS:[^=]+=(.+)$'
# One project at a time, four compiles in it.
if (-not $env:_CL_) { $env:_CL_ = '/MP4' }
# No MSBuild node outlives the build.
$env:MSBUILDDISABLENODEREUSE = '1'

function Build-Fixture([string]$name, [string]$commit, [bool]$shift, [bool]$defaults = $false) {
    $source = Join-Path $Build "$name-source"
    $output = Join-Path $Build $name
    # A kept build folder holds the last run's source: the fixture starts from its commit again.
    if (Test-Path $source) {
        git -C $repo worktree remove --force $source 2>$null
        if (Test-Path $source) { Remove-Item -Recurse -Force $source }
    }
    git -C $repo worktree prune
    git -C $repo worktree add --detach $source $commit
    if ($LASTEXITCODE) { throw "Creating $name source failed" }
    # The historical source predates the runner's manifest-mode toolchain.
    if (-not (Test-Path "$source/vcpkg.json")) {
        Copy-Item "$repo/vcpkg.json" "$source/vcpkg.json"
        # and the overlay ports it names
        if (-not (Test-Path "$source/dep")) { Copy-Item -Recurse "$repo/dep" "$source/dep" }
    }
    if ($shift) {
        $header = Join-Path $source 'tmux.h'
        $text = [IO.File]::ReadAllText($header)
        $needle = 'KEYC_MOUSE_KEY(MOUSEMOVE),'
        if (-not $text.Contains($needle)) { throw 'Mouse enum fixture anchor missing' }
        [IO.File]::WriteAllText($header, $text.Replace($needle, "KEYC_UPGRADE_TEST_SHIFT,`n`t$needle"))
    }
    # Defaults unlike this build's: prefix i changed, F9 added, z removed.
    if ($defaults) {
        $bindings = Join-Path $source 'key-bindings.c'
        $text = [IO.File]::ReadAllText($bindings)
        $info = '"bind -N ''Display window information'' i { display-message }",'
        $zoom = '"bind -N ''Zoom the active pane'' z { resize-pane -Z }",'
        if (-not $text.Contains($info) -or -not $text.Contains($zoom)) {
            throw 'Default binding fixture anchors missing'
        }
        $text = $text.Replace($info, '"bind -N ''Display window information'' i { display-message OLD_I }", "bind -N ''Old default'' F9 { display-message OLD_F9 }",')
        [IO.File]::WriteAllText($bindings, $text.Replace($zoom, ''))
    }
    $cmakeArgs = @('-S', $source, '-B', $output, '-G', 'Visual Studio 17 2022', '-A', 'x64',
        "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake",
        "-DVCPKG_INSTALLED_DIR=$dependencyInstall",
        '-DVCPKG_TARGET_TRIPLET=x64-windows-static')
    if ($env:VCPKG_MANIFEST_MODE -eq 'OFF') { $cmakeArgs += '-DVCPKG_MANIFEST_MODE=OFF' }
    if ($installOptions) { $cmakeArgs += "-DVCPKG_INSTALL_OPTIONS=$($installOptions.Matches[0].Groups[1].Value)" }
    & $CMake @cmakeArgs
    if ($LASTEXITCODE) { throw "Configuring $name failed" }
    & $CMake --build $output --config Debug --parallel 1
    if ($LASTEXITCODE) { throw "Building $name failed" }
    # Built, the source leaves no worktree registered in the checkout.
    git -C $repo worktree remove --force $source
    Copy-Item "$Conpty/conpty.dll", "$Conpty/OpenConsole.exe" "$output/Debug/"
    return "$output/Debug/tmux.exe"
}

if (-not $LegacyExecutable) {
    git -C $repo fetch --no-tags origin $legacyCommit
    if ($LASTEXITCODE) { throw 'Fetching pre-footer regression source failed' }
    $LegacyExecutable = Build-Fixture 'legacy-keys' $legacyCommit $false | Select-Object -Last 1
}
$shifted = Build-Fixture 'shifted-keys' 'HEAD' $true | Select-Object -Last 1
$defaults = Build-Fixture 'other-defaults' 'HEAD' $false $true | Select-Object -Last 1
$env:TEST_LEGACY_TMUX = $LegacyExecutable.Replace('\', '/')
$env:TEST_SHIFTED_TMUX = $shifted.Replace('\', '/')
$env:TEST_DEFAULTS_TMUX = $defaults.Replace('\', '/')
$env:TEST_TMUX = "$Conpty/tmux.exe".Replace('\', '/')
if ($env:GITHUB_ENV) {
    "TEST_LEGACY_TMUX=$env:TEST_LEGACY_TMUX" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
    "TEST_SHIFTED_TMUX=$env:TEST_SHIFTED_TMUX" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
    "TEST_DEFAULTS_TMUX=$env:TEST_DEFAULTS_TMUX" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
}
