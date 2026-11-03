# Publish this fork's release as `tmux` to \\NelsonNAS\tools (Nelson's home
# setup; see shell-config-profile-home claude\topics\home-tools.md).
# CI on Forgejo releases every master commit whose run passed, tagged
# `git describe` (e.g. v3.6a-win32.7-55-g529c862f), so only committed, pushed
# code is published.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (git status --porcelain) { throw 'commit first: a published version has to match a commit' }
git fetch -q origin
if (git log --oneline '@{u}..HEAD') { throw 'push first: the published commit has to be on Forgejo' }

$commit = git rev-parse HEAD
$server = 'https://forgejo.romaine.life'
$repo = (git remote get-url origin) -replace "^$([regex]::Escape($server))/|\.git$", ''
$cred = "protocol=https`nhost=forgejo.romaine.life`n`n" | git credential fill
$token = ($cred | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
if (-not $token) { throw 'git has no credential for forgejo.romaine.life' }
$headers = @{ Authorization = "token $token" }
$api = "$server/api/v1/repos/$repo"

# The release CI makes for this commit; it exists once the whole run (macOS
# included) has passed.
$release = $null
foreach ($attempt in 1..120) {
    $release = Invoke-RestMethod "$api/releases?limit=50" -Headers $headers |
        Where-Object { $_.target_commitish -eq $commit } | Select-Object -First 1
    if ($release) {
        $names = @($release.assets.name)
        $zipName = "tmux-windows-$($release.tag_name).zip"
        if ($zipName -in $names -and "$zipName.sha256" -in $names) { break }
    }
    $state = (Invoke-RestMethod "$api/commits/$commit/status" -Headers $headers).state
    if ($state -in 'failure', 'error') { throw "CI failed for $commit`: $server/$repo/actions" }
    Start-Sleep -Seconds 30
}
if (-not $release) { throw "no release for $commit after an hour: $server/$repo/actions" }
$version = $release.tag_name

$dir = Join-Path ([IO.Path]::GetTempPath()) "tmux-$version"
Remove-Item $dir, "$dir.zip", "$dir.zip.sha256" -Recurse -Force -ErrorAction SilentlyContinue
$zip = $release.assets | Where-Object name -eq "tmux-windows-$version.zip"
$sum = $release.assets | Where-Object name -eq "tmux-windows-$version.zip.sha256"
if (-not $zip -or -not $sum) { throw "release $version is missing its assets: $server/$repo/releases/tag/$version" }
Invoke-WebRequest $zip.browser_download_url -Headers $headers -OutFile "$dir.zip"
Invoke-WebRequest $sum.browser_download_url -Headers $headers -OutFile "$dir.zip.sha256"
$expected = ((Get-Content "$dir.zip.sha256" -Raw) -split '\s+')[0]
if ((Get-FileHash "$dir.zip" -Algorithm SHA256).Hash -ne $expected) { throw "tmux-windows-$version.zip does not match its SHA256" }
Expand-Archive "$dir.zip" $dir

publish-tool -Name tmux -Version $version -Path $dir `
    -Entry tmux.exe -Repo "$server/$repo" -Commit $commit

# Every open tab moves onto the release in place, and takes the config again, which
# a new build can make valid: the home profile's sync-servers.ps1, which home-sync
# also runs. The release runs from the Drive copy once Synology Drive has it, as new
# tabs do.
$local = Join-Path $HOME "tools\tmux\$version\tmux.exe"
foreach ($attempt in 1..24) {
    if (Test-Path $local) { break }
    Start-Sleep -Seconds 5
}
$sync = '\\NelsonNAS\files\shell-config-profile-home\tmux\sync-servers.ps1'
if (Test-Path $sync) {
    foreach ($s in & $sync) {
        Write-Host "$($s.Server): $($s.Build); config $($s.Config)"
    }
}
