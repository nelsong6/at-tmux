# vcpkg's only download source (the workflows' X_VCPKG_ASSET_SOURCES): fetches a port's source or
# a tool vcpkg asks for through Artifact Keeper's cache of its host, into the file vcpkg names.
# vcpkg checks the file's SHA512 itself. A host with no cache fails the build, naming it.
param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'

$cache = 'https://artifacts.home.romaine.life/general'
$through = switch -Regex ($Url) {
    '^https://github\.com/(.+)$' { "$cache/github/$($Matches[1])"; break }
    '^https://(mirror|repo)\.msys2\.org/(.+)$' { "$cache/msys2/$($Matches[2])"; break }
    '^https://www\.python\.org/ftp/python/(.+)$' { "$cache/python-downloads/$($Matches[1])"; break }
}
if (-not $through) {
    [Console]::Error.WriteLine("vcpkg asked for $Url, and no Artifact Keeper cache serves its host: add one (artifact-keeper k8s/caches.txt) and a line here")
    exit 1
}
Invoke-WebRequest $through -OutFile $Destination
