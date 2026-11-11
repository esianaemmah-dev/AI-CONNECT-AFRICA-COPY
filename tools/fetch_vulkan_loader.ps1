<#
.SYNOPSIS
  Fetches the Vulkan loader (vulkan-1.dll) that the Windows build must ship.

.DESCRIPTION
  This is not about using the GPU — the translation engine runs CPU-only
  (nGpuLayers: 0). It is about being able to load llama.cpp at all.

  llm_llamacpp's prebuilt Windows bundle links its ggml backends statically,
  so ggml.dll carries a *load-time* import on ggml-vulkan.dll, which imports
  vulkan-1.dll:

      vulkan-1.dll <- ggml-vulkan.dll <- ggml.dll <- llama.dll

  vulkan-1.dll ships with GPU drivers. On a Windows machine running generic
  or old display drivers — exactly the low-end laptops this project targets —
  it is absent, every DLL above it fails to load with error 126
  (ERROR_MOD_NOT_FOUND), llm_llamacpp's helper isolate dies during backend
  init, and translation silently stops working. Android is unaffected:
  libvulkan.so is part of the OS.

  Shipping the loader beside the executable fixes the import. With no Vulkan
  driver installed the loader simply enumerates zero devices and the Vulkan
  backend is skipped, which is what we want anyway — verified on an Intel
  i7-4600U with no Vulkan runtime, where all five DLLs then load cleanly.

  Source: LunarG Vulkan Runtime Components (the Khronos Vulkan-Loader
  reference loader). Apache-2.0, redistributable — see the LICENSE note
  written next to the DLL.

  Run before `flutter build windows`. Re-run to pick up a newer loader.
#>
$ErrorActionPreference = 'Stop'

$destDir = Join-Path $PSScriptRoot '..\windows\third_party\vulkan'
$dll = Join-Path $destDir 'vulkan-1.dll'

if (Test-Path $dll) {
  Write-Host "Already present: $dll" -ForegroundColor Green
  exit 0
}

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$url = 'https://sdk.lunarg.com/sdk/download/latest/windows/vulkan-runtime-components.zip'
$zip = Join-Path $env:TEMP 'vulkan-runtime-components.zip'
$extract = Join-Path $env:TEMP 'vulkan-runtime-components'

Write-Host "Downloading $url ..."
$downloaded = $false

try {
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  $downloaded = $true
} catch {
  # LunarG's "latest" endpoint can temporarily point at a just-published patch
  # where vulkan-runtime-components.zip is not available yet (HTTP 404). If the
  # error names that version, fall back to the previous patch version.
  $message = $_.Exception.Message
  $latestVersion = [regex]::Match(
    $message,
    'for windows (?<ver>\d+\.\d+\.\d+\.\d+)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  ).Groups['ver'].Value

  if (-not [string]::IsNullOrWhiteSpace($latestVersion)) {
    $parts = $latestVersion.Split('.') | ForEach-Object { [int]$_ }
    $baseVersion = "$($parts[0]).$($parts[1])"
    $latestBuild = $parts[2]
    $latestPatch = $parts[3]
    $oldestBuild = [Math]::Max($latestBuild - 10, 0)

    for ($candidateBuild = $latestBuild; $candidateBuild -ge $oldestBuild -and -not $downloaded; $candidateBuild--) {
      $patchStart = if ($candidateBuild -eq $latestBuild) {
        [Math]::Max($latestPatch - 1, 0)
      } else {
        9
      }

      for ($candidatePatch = $patchStart; $candidatePatch -ge 0 -and -not $downloaded; $candidatePatch--) {
        $candidateVersion = "$baseVersion.$candidateBuild.$candidatePatch"
        $candidateUrl = "https://sdk.lunarg.com/sdk/download/$candidateVersion/windows/vulkan-runtime-components.zip"
        Write-Warning "Latest components missing for $latestVersion; trying $candidateVersion ..."

        try {
          Invoke-WebRequest -Uri $candidateUrl -OutFile $zip -UseBasicParsing
          $downloaded = $true
        } catch {
          continue
        }
      }
    }
  }

  if (-not $downloaded) {
    throw
  }
}

if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $extract -Force

# Layout is VulkanRT-X64-<version>-Components/{x64,x86}/vulkan-1.dll. Take x64
# explicitly: the x86 copy has the same filename and would silently produce an
# unloadable 32-bit dependency.
$found = Get-ChildItem $extract -Recurse -Filter 'vulkan-1.dll' |
  Where-Object { $_.Directory.Name -eq 'x64' } |
  Select-Object -First 1

if (-not $found) {
  throw "vulkan-1.dll (x64) was not found under $extract"
}

Copy-Item $found.FullName $dll -Force

@'
vulkan-1.dll is the Khronos Vulkan loader, redistributed here from the LunarG
Vulkan Runtime Components package.

  Project: https://github.com/KhronosGroup/Vulkan-Loader
  License: Apache License 2.0

It is bundled only so that llama.cpp's ggml.dll can satisfy its load-time
import chain on machines with no Vulkan-capable display driver. The app does
not use the GPU for inference.
'@ | Out-File -Encoding utf8 (Join-Path $destDir 'LICENSE.vulkan-loader.txt')

$size = (Get-Item $dll).Length
$version = $found.VersionInfo.FileVersion
Write-Host "Fetched vulkan-1.dll ($size bytes, version $version) -> $dll" -ForegroundColor Green
