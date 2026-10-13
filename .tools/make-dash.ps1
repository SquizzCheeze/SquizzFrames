# Generates Media\Textures\dash.png, the tile the Dispels indicator's
# "Animated Border" (marching ants) repeats along each edge.
#
# 16x16: the left half opaque white, the right half transparent. The edge
# strips tint it with the dispel type's colour and repeat it with REPEAT wrap,
# so only the on/off ratio matters here, not the size (the strip's texcoords
# set the on-screen dash length -- see DISPEL_ANTS_PERIOD in
# AuraEngineIndicators.lua). Power-of-two so REPEAT wrap is safe.
#
#   powershell -ExecutionPolicy Bypass -File .tools\make-dash.ps1
param(
    [string]$OutPath = (Join-Path $PSScriptRoot '..\Media\Textures\dash.png')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size = 16
$bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
for ($x = 0; $x -lt $Size; $x++) {
    for ($y = 0; $y -lt $Size; $y++) {
        if ($x -lt ($Size / 2)) {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, 255, 255, 255))
        } else {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
        }
    }
}
$bmp.Save([System.IO.Path]::GetFullPath($OutPath), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "Wrote $OutPath"
