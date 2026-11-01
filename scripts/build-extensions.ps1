# 构建两个编辑器插件端
# ----------------------
# 插件本身不重写协议：把 Alighieri Web 静态站（../Alighieri/out）随包携带，
# 由插件内的本地 HTTP 服务提供。另一个端是本地书架页面。
# 打包时插件不亲自上阵，只负责带路。
#
# 产物：
#   dist/Alighieri-0.1.0-vscode.vsix
#   dist/Alighieri-0.1.0-obsidian.zip
#
# 用法：powershell -ExecutionPolicy Bypass -File scripts/build-extensions.ps1

$ErrorFlags = $ErrorActionPreference
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = Split-Path -Parent $PSScriptRoot
$WebSrc = Join-Path $Root "..\Alighieri\out"
$Shared = Join-Path $Root "extensions\shared"
$Dist = Join-Path $Root "dist"

if (-not (Test-Path $WebSrc)) {
  throw "找不到 Web 静态站：$WebSrc。请先在 Alighieri 仓库执行 npm run build:pages。"
}

New-Item -ItemType Directory -Force $Dist | Out-Null

# 插件自带的是 Alighieri Web 静态站的**打包副本**（原仓库不动）。
# 版权归 OpenMasons 后，副本里的底部版权统一改成 "Alighieri by OpenMasons"。
# 原件保持原样，副本才换个署名。
function Set-PackagedCopyright($webRoot) {
  Get-ChildItem -Recurse -File $webRoot | Where-Object {
    $_.Extension -in ".js", ".html", ".txt", ".json", ".xml", ".webmanifest"
  } | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    $changed = $false
    if ($text.Contains("© 2026 Alighieri")) {
      $text = $text.Replace("© 2026 Alighieri", "© 2026 Alighieri by OpenMasons")
      $changed = $true
    }
    # Next.js 的字典 chunk 把 © 写成 \xa9 转义，HTML 里才是字面字符——同一个符号，两种写法
    if ($text.Contains("\xa9 2026 Alighieri")) {
      $text = $text.Replace("\xa9 2026 Alighieri", "\xa9 2026 Alighieri by OpenMasons")
      $changed = $true
    }
    if ($changed) {
      [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
  }
}

# Web 静态站的许可名称还停留在旧协议名上；打包副本统一改为 ANPL 1.0。
# 原仓库不动，只改随包携带的这份副本——衣柜只整理出门的那套。
function Set-PackagedLicenses($webRoot) {
  $pairs = @(
    @("Alighieri 连载许可（推荐）", "ANPL 1.0（推荐）"),
    @("Alighieri 连载许可 v1", "ANPL 1.0"),
    @("Alighieri 连载许可", "ANPL 1.0"),
    @("Alighieri Serial Licence (recommended)", "ANPL 1.0 (recommended)"),
    @("Alighieri Serial Licence", "ANPL 1.0"),
    @("Alighieri Serial", "ANPL 1.0"),
    @("Alighieri 連載ライセンス（推奨）", "ANPL 1.0（推奨）"),
    @("Alighieri 連載ライセンス", "ANPL 1.0"),
    @("Alighieri 연작 허가(추천)", "ANPL 1.0(추천)"),
    @("Alighieri 연작 허가", "ANPL 1.0"),
    @("Лицензия Alighieri для сериалов (рекомендуется)", "ANPL 1.0 (рекомендуется)"),
    @("Alighieri: сериалы", "ANPL 1.0")
  )
  Get-ChildItem -Recurse -File $webRoot | Where-Object {
    $_.Extension -in ".js", ".html", ".txt"
  } | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    $changed = $false
    foreach ($pair in $pairs) {
      if ($text.Contains($pair[0])) {
        $text = $text.Replace($pair[0], $pair[1])
        $changed = $true
      }
    }
    if ($changed) {
      [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
  }
}

# ZIP / VSIX 规范要求条目名用正斜杠；.NET 的 CreateFromDirectory 在 Windows 上
# 会写成反斜杠，VS Code 能装，Open VSX 却找不到 extension/package.json。
# 跨平台打包的老毛病，这里手动正过来。
function New-ZipFromDirectory($source, $dest) {
  if (Test-Path $dest) { Remove-Item -Force $dest }
  $zip = [IO.Compression.ZipFile]::Open(
    $dest,
    [IO.Compression.ZipArchiveMode]::Create
  )
  try {
    Get-ChildItem -Recurse -File $source | ForEach-Object {
      $relative = $_.FullName.Substring($source.Length + 1) -replace '\\', '/'
      $entry = $zip.CreateEntry(
        $relative,
        [IO.Compression.CompressionLevel]::Optimal
      )
      $entry.LastWriteTime = $_.LastWriteTime
      $out = $entry.Open()
      try {
        $in = [IO.File]::OpenRead($_.FullName)
        try { $in.CopyTo($out) } finally { $in.Dispose() }
      } finally { $out.Dispose() }
    }
  } finally {
    $zip.Dispose()
  }
}

# Web 页脚的「赞助我们」入口改为本地 /about 页面；只改打包副本，原件不碰。
function Set-PackagedAbout($webRoot) {
  $pairs = @(
    @('{labelKey:"footer.sponsor",href:"/sponsor"}', '{labelKey:"footer.sponsor",href:"/about"}'),
    @('"footer.sponsor":"赞助我们"', '"footer.sponsor":"关于我们"'),
    @('"footer.sponsor":"Sponsor us"', '"footer.sponsor":"About us"'),
    @('"footer.sponsor":"支援する"', '"footer.sponsor":"私たちについて"'),
    @('"footer.sponsor":"후원하기"', '"footer.sponsor":"우리에 관하여"'),
    @('"footer.sponsor":"Поддержать нас"', '"footer.sponsor":"О нас"'),
    @('href="/sponsor/">赞助我们</a>', 'href="/about/">关于我们</a>'),
    @('href="/sponsor/">Sponsor us</a>', 'href="/about/">About us</a>'),
    @('href="/sponsor/">支援する</a>', 'href="/about/">私たちについて</a>'),
    @('href="/sponsor/">후원하기</a>', 'href="/about/">우리에 관하여</a>'),
    @('href="/sponsor/">Поддержать нас</a>', 'href="/about/">О нас</a>')
  )
  Get-ChildItem -Recurse -File $webRoot | Where-Object {
    $_.Extension -in ".js", ".html", ".txt"
  } | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    $changed = $false
    foreach ($pair in $pairs) {
      if ($text.Contains($pair[0])) {
        $text = $text.Replace($pair[0], $pair[1])
        $changed = $true
      }
    }
    if ($changed) {
      [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
  }
}

# ---------------------------------------------------------------- VS Code
$VsStage = Join-Path $Dist "extensions\vscode"
$VsPkg = Join-Path $VsStage "extension"
Remove-Item -Recurse -Force $VsStage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $VsPkg | Out-Null

Copy-Item (Join-Path $Root "extensions\vscode\package.json") $VsPkg
Copy-Item (Join-Path $Root "extensions\vscode\extension.js") $VsPkg
New-Item -ItemType Directory -Force (Join-Path $VsPkg "shared") | Out-Null
Copy-Item (Join-Path $Shared "local-library.js") (Join-Path $VsPkg "shared")
Copy-Item (Join-Path $Shared "server.js") (Join-Path $VsPkg "shared")
Copy-Item -Recurse (Join-Path $Shared "ui") (Join-Path $VsPkg "ui")
Copy-Item -Recurse $WebSrc (Join-Path $VsPkg "web")
Set-PackagedCopyright (Join-Path $VsPkg "web")
Set-PackagedLicenses (Join-Path $VsPkg "web")
Set-PackagedAbout (Join-Path $VsPkg "web")
New-Item -ItemType Directory -Force (Join-Path $VsPkg "media") | Out-Null
Copy-Item (Join-Path $Root "extensions\vscode\media\icon.svg") (Join-Path $VsPkg "media")
Copy-Item (Join-Path $Root "..\Alighieri\public\icon-192.png") (Join-Path $VsPkg "media\icon-192.png")

$VsixManifest = @'
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="alighieri" Version="0.1.2" Publisher="OpenMasons" />
    <DisplayName>Alighieri</DisplayName>
    <Description xml:space="preserve">在 VS Code 里读 Alighieri：完整网络客户端 + 本地 TXT / EPUB / Markdown 书架。</Description>
    <Tags>novel,reader,epub,markdown,p2p</Tags>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.90.0" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
'@
[IO.File]::WriteAllText((Join-Path $VsStage "extension.vsixmanifest"), $VsixManifest, (New-Object Text.UTF8Encoding($false)))

$ContentTypes = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="js" ContentType="application/javascript" />
  <Default Extension="svg" ContentType="image/svg+xml" />
  <Default Extension="png" ContentType="image/png" />
  <Default Extension="css" ContentType="text/css" />
  <Default Extension="html" ContentType="text/html" />
  <Default Extension="txt" ContentType="text/plain" />
  <Default Extension="xml" ContentType="application/xml" />
  <Default Extension="webmanifest" ContentType="application/manifest+json" />
  <Default Extension="vsixmanifest" ContentType="text/xml" />
  <Default Extension="map" ContentType="application/json" />
</Types>
'@
[IO.File]::WriteAllText((Join-Path $VsStage "[Content_Types].xml"), $ContentTypes, (New-Object Text.UTF8Encoding($false)))

$VsixOut = Join-Path $Dist "Alighieri-0.1.2-vscode.vsix"
New-ZipFromDirectory $VsStage $VsixOut

# ---------------------------------------------------------------- Obsidian
$ObStage = Join-Path $Dist "extensions\obsidian"
$ObPkg = Join-Path $ObStage "alighieri"
Remove-Item -Recurse -Force $ObStage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $ObPkg | Out-Null

Copy-Item (Join-Path $Root "extensions\obsidian\manifest.json") $ObPkg
Copy-Item (Join-Path $Root "extensions\obsidian\main.js") $ObPkg
Copy-Item (Join-Path $Root "extensions\obsidian\styles.css") $ObPkg
New-Item -ItemType Directory -Force (Join-Path $ObPkg "shared") | Out-Null
Copy-Item (Join-Path $Shared "local-library.js") (Join-Path $ObPkg "shared")
Copy-Item (Join-Path $Shared "server.js") (Join-Path $ObPkg "shared")
Copy-Item -Recurse (Join-Path $Shared "ui") (Join-Path $ObPkg "ui")
Copy-Item -Recurse $WebSrc (Join-Path $ObPkg "web")
Set-PackagedCopyright (Join-Path $ObPkg "web")
Set-PackagedLicenses (Join-Path $ObPkg "web")
Set-PackagedAbout (Join-Path $ObPkg "web")

$ObOut = Join-Path $Dist "Alighieri-0.1.2-obsidian.zip"
New-ZipFromDirectory $ObStage $ObOut

Write-Output "VS Code : $VsixOut ($([math]::Round((Get-Item $VsixOut).Length / 1MB, 2)) MB)"
Write-Output "Obsidian: $ObOut ($([math]::Round((Get-Item $ObOut).Length / 1MB, 2)) MB)"
Write-Output "解包目录: $VsPkg"
Write-Output "          $ObPkg"

$ErrorActionPreference = $ErrorFlags