param([string]$CMake = 'cmake', [string]$LegacyExecutable)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$legacyCommit = '529c862fae20fa4e3c55ad342a4999011ab291cb'
$dependencyCache = Select-String -Path "$repo/build/CMakeCache.txt" -Pattern '^VCPKG_INSTALLED_DIR:[^=]+=(.+)$'
if (-not $dependencyCache) { throw 'Current build dependency location missing' }
$dependencyInstall = $dependencyCache.Matches[0].Groups[1].Value

function Build-Fixture([string]$name, [string]$commit, [bool]$shift) {
    $source = Join-Path $repo "build/$name-source"
    $output = Join-Path $repo "build/$name"
    git -C $repo worktree add --detach $source $commit
    if ($LASTEXITCODE) { throw "Creating $name source failed" }
    # The historical source predates the runner's manifest-mode toolchain.
    if (-not (Test-Path "$source/vcpkg.json")) {
        Copy-Item "$repo/vcpkg.json" "$source/vcpkg.json"
    }
    if ($shift) {
        $header = Join-Path $source 'tmux.h'
        $text = [IO.File]::ReadAllText($header)
        $needle = 'KEYC_MOUSE_KEY(MOUSEMOVE),'
        if (-not $text.Contains($needle)) { throw 'Mouse enum fixture anchor missing' }
        [IO.File]::WriteAllText($header, $text.Replace($needle, "KEYC_UPGRADE_TEST_SHIFT,`n`t$needle"))
    }
    $cmakeArgs = @('-S', $source, '-B', $output, '-G', 'Visual Studio 17 2022', '-A', 'x64',
        "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake",
        "-DVCPKG_INSTALLED_DIR=$dependencyInstall",
        '-DVCPKG_TARGET_TRIPLET=x64-windows-static')
    if ($env:VCPKG_MANIFEST_MODE -eq 'OFF') { $cmakeArgs += '-DVCPKG_MANIFEST_MODE=OFF' }
    & $CMake @cmakeArgs
    if ($LASTEXITCODE) { throw "Configuring $name failed" }
    & $CMake --build $output --config Debug --parallel 4
    if ($LASTEXITCODE) { throw "Building $name failed" }
    Copy-Item "$repo/build/upgrade/conpty.dll", "$repo/build/upgrade/OpenConsole.exe" "$output/Debug/"
    return "$output/Debug/tmux.exe"
}

if (-not $LegacyExecutable) {
    git -C $repo fetch --no-tags origin $legacyCommit
    if ($LASTEXITCODE) { throw 'Fetching pre-footer regression source failed' }
    $LegacyExecutable = Build-Fixture 'legacy-keys' $legacyCommit $false | Select-Object -Last 1
}
$shifted = Build-Fixture 'shifted-keys' 'HEAD' $true | Select-Object -Last 1
$env:TEST_LEGACY_TMUX = $LegacyExecutable.Replace('\', '/')
$env:TEST_SHIFTED_TMUX = $shifted.Replace('\', '/')
$env:TEST_TMUX = './build/upgrade/tmux.exe'
if ($env:GITHUB_ENV) {
    "TEST_LEGACY_TMUX=$env:TEST_LEGACY_TMUX" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
    "TEST_SHIFTED_TMUX=$env:TEST_SHIFTED_TMUX" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
}
