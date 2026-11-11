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

$catalogUrl = 'https://vulkan.lunarg.com/sdk/files.json'
$catalogResponse = Invoke-WebRequest -Uri $catalogUrl -UseBasicParsing
$catalog = $catalogResponse.Content | ConvertFrom-Json -AsHashtable

if (-not $catalog.ContainsKey('windows')) {
  throw "LunarG did not return a Windows SDK file catalog"
}

$runtimePackage = $null
$runtimeVersion = $null
foreach ($version in ($catalog.windows.Keys | Sort-Object { [version]$_ } -Descending)) {
  $runtimePackage = $catalog.windows[$version].files |
    Where-Object {
      $_.name -eq 'Runtime zip' -and
      $_.uploaded -eq $true -and
      $_.file_name -match '^VulkanRT-X64-.+-Components\.zip$'
    } |
    Select-Object -First 1
  if ($runtimePackage) {
    $runtimeVersion = $version
    break
  }
}

if (-not $runtimePackage) {
  throw "No published x64 Vulkan Runtime Components ZIP was found in the LunarG catalog"
}

$zip = Join-Path $env:TEMP $runtimePackage.file_name
$extract = Join-Path $env:TEMP "vulkan-runtime-components-$runtimeVersion"
$url = "https://sdk.lunarg.com/sdk/download/$runtimeVersion/windows/$($runtimePackage.file_name)"

Write-Host "Downloading $url ..."
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

$actualHash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
if ($actualHash -ne $runtimePackage.sha) {
  throw "SHA-256 mismatch for $($runtimePackage.file_name): expected $($runtimePackage.sha), got $actualHash"
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
Write-Host "Fetched vulkan-1.dll ($size bytes, file version $version; runtime $runtimeVersion) -> $dll" -ForegroundColor Green
