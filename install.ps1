#requires -Version 5.1
<#
.SYNOPSIS
  Installs the better Firefox context menu (chrome/userChrome.css) into your profile(s).

.DESCRIPTION
  With no arguments, installs into the default profile of every Firefox install it
  finds (release, Nightly, ...). Run from a clone it uses the local files; run from
  the web it downloads them.

.EXAMPLE
  irm https://raw.githubusercontent.com/TimurCravtov/BetterFirefoxContextMenu/main/install.ps1 | iex

.EXAMPLE
  # With options (piping can't take parameters, so use a script block):
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/TimurCravtov/BetterFirefoxContextMenu/main/install.ps1))) -Uninstall

.EXAMPLE
  .\install.ps1 -List
  .\install.ps1 -ProfileName abcd1234.default-release
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string[]]$ProfileName,   # install into these profile folder names instead of the detected defaults
    [switch]$List,            # just list profiles
    [switch]$Uninstall,       # remove the stylesheet (restores a backup if one was made)
    [string]$Ref = 'main'     # git branch/tag to download from
)

$ErrorActionPreference = 'Stop'
$Repo      = 'TimurCravtov/BetterFirefoxContextMenu'
$Marker    = 'Better page context menu'     # first-line text that identifies our stylesheet
$PrefName  = 'toolkit.legacyUserProfileCustomizations.stylesheets'
$FirefoxDir = Join-Path $env:APPDATA 'Mozilla\Firefox'

function Test-Ours($path) {
    (Test-Path $path) -and ((Get-Content $path -Raw) -match [regex]::Escape($Marker))
}

function Get-ProfileDirs {
    Get-ChildItem (Join-Path $FirefoxDir 'Profiles') -Directory -ErrorAction SilentlyContinue
}

# Profiles that Firefox installs actually launch, from profiles.ini ([Install*] sections).
function Get-DefaultProfileDirs {
    $ini = Join-Path $FirefoxDir 'profiles.ini'
    $found = @()
    if (Test-Path $ini) {
        $found = Select-String -Path $ini -Pattern '^\[Install' -Context 0, 3 | ForEach-Object {
            $_.Context.PostContext | ForEach-Object {
                if ($_ -match '^Default=(.+)$') { Join-Path $FirefoxDir ($Matches[1] -replace '/', '\') }
            }
        }
        if (-not $found) {   # older layout: Default=1 inside a [ProfileN] section
            $path = $null
            foreach ($line in Get-Content $ini) {
                if ($line -match '^\[') { $path = $null }
                elseif ($line -match '^Path=(.+)$') { $path = $Matches[1] }
                elseif ($line -match '^Default=1$' -and $path) { $found += Join-Path $FirefoxDir ($path -replace '/', '\') }
            }
        }
    }
    $found | Where-Object { Test-Path $_ } | Select-Object -Unique
}

if ($List) {
    $defaults = @(Get-DefaultProfileDirs)
    Get-ProfileDirs | ForEach-Object {
        $tag = if ($defaults -contains $_.FullName) { '  (in use)' } else { '' }
        "$($_.Name)$tag"
    }
    return
}

# Pick targets.
if ($ProfileName) {
    $targets = $ProfileName | ForEach-Object {
        $p = Join-Path $FirefoxDir "Profiles\$_"
        if (-not (Test-Path $p)) { throw "Profile not found: $p (try -List)" }
        $p
    }
} else {
    $targets = @(Get-DefaultProfileDirs)
    if (-not $targets) { throw "Couldn't find a Firefox profile. Run with -List, then -ProfileName <name>." }
}

if (Get-Process firefox -ErrorAction SilentlyContinue) {
    Write-Warning 'Firefox is running; fully quit and reopen it for the change to show.'
}

# Locate the stylesheet: local clone first, otherwise download.
$localCss = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'chrome\userChrome.css' }
if (-not $Uninstall) {
    if ($localCss -and (Test-Path $localCss)) {
        $css = Get-Content $localCss -Raw -Encoding UTF8
    } else {
        $url = "https://raw.githubusercontent.com/$Repo/$Ref/chrome/userChrome.css"
        Write-Host "Downloading $url"
        $css = (Invoke-WebRequest $url -UseBasicParsing).Content
        if ($css -is [byte[]]) { $css = [Text.Encoding]::UTF8.GetString($css) }
    }
    if ($css -notmatch [regex]::Escape($Marker)) { throw 'Downloaded file does not look like the stylesheet; aborting.' }
}

$utf8 = New-Object Text.UTF8Encoding $false

foreach ($target in $targets) {
    $chrome = Join-Path $target 'chrome'
    $file   = Join-Path $chrome 'userChrome.css'
    $backup = "$file.bak"
    $name   = Split-Path $target -Leaf

    if ($Uninstall) {
        if (Test-Ours $file) {
            Remove-Item $file
            if (Test-Path $backup) { Move-Item $backup $file }
            Write-Host "Removed from $name"
        } else {
            Write-Host "Nothing to remove in $name"
        }
        continue
    }

    New-Item -ItemType Directory -Force $chrome | Out-Null

    # Keep someone's existing, different userChrome.css instead of silently overwriting it.
    if ((Test-Path $file) -and -not (Test-Path $backup) -and -not (Test-Ours $file)) {
        Copy-Item $file $backup
        Write-Host "Backed up your existing userChrome.css to userChrome.css.bak"
    }
    [IO.File]::WriteAllText($file, $css, $utf8)

    # Enable stylesheet loading (user.js wins over prefs.js on every start).
    $userJs = Join-Path $target 'user.js'
    $line = "user_pref(`"$PrefName`", true);"
    if (Test-Path $userJs) {
        $text = Get-Content $userJs -Raw
        if ($text -match [regex]::Escape($PrefName)) {
            $text = $text -replace "user_pref\(\s*[`"']$([regex]::Escape($PrefName))[`"']\s*,\s*\w+\s*\)\s*;", $line
            [IO.File]::WriteAllText($userJs, $text, $utf8)
        } else {
            Add-Content $userJs "`n$line"
        }
    } else {
        [IO.File]::WriteAllText($userJs, "$line`n", $utf8)
    }

    Write-Host "Installed into $name"
}

if ($Uninstall) { Write-Host 'Done. Restart Firefox.' } else { Write-Host 'Done. Fully quit and reopen Firefox, then right-click a page.' }
