# Generates Media\Textures\dash.tga, the strip the Dispels indicator's
# "Animated Border" (marching ants) slides along each edge.
#
# 2048 x 4, the dashes DRAWN IN along its length: 4 px on, 4 px off, 256
# periods. Each 1024-unit edge strip shows a slice of it (0..1, 0..0.5 or
# 0..0.25 of its length), which puts 256, 128 or 64 periods on the strip: the
# Short / Medium / Long dash lengths (4, 8 and 16 units a period). Keep in step
# with DISPEL_ANTS_IMAGE_* in AuraEngineIndicators.lua.
#
# Deliberately NOT a small tile repeated with REPEAT wrap: that was the first
# version (dash.png, 16x16) and in game the strips rendered nothing at all --
# without the repeat, a texcoord past 1 stretches the tile's last (transparent)
# column across the strip. A long image needs no wrap mode.
#
# TGA because every other texture in Media is one; written by hand since
# System.Drawing has no TGA encoder. Uncompressed 32-bit BGRA, top-left origin.
#
#   powershell -ExecutionPolicy Bypass -File .tools\make-dash.ps1
param(
    [string]$OutPath = (Join-Path $PSScriptRoot '..\Media\Textures\dash.tga')
)
$ErrorActionPreference = 'Stop'

$W = 2048
$H = 4
$On = 4
$Period = 8

$bytes = New-Object byte[] (18 + $W * $H * 4)
$bytes[2]  = 2                     # uncompressed true-colour
$bytes[12] = $W -band 0xFF
$bytes[13] = ($W -shr 8) -band 0xFF
$bytes[14] = $H -band 0xFF
$bytes[15] = ($H -shr 8) -band 0xFF
$bytes[16] = 32                    # bits per pixel
$bytes[17] = 0x28                  # 8 alpha bits, top-left origin

$i = 18
for ($y = 0; $y -lt $H; $y++) {
    for ($x = 0; $x -lt $W; $x++) {
        $a = 0
        if (($x % $Period) -lt $On) { $a = 255 }
        $bytes[$i] = 255; $bytes[$i + 1] = 255; $bytes[$i + 2] = 255; $bytes[$i + 3] = $a
        $i += 4
    }
}
[System.IO.File]::WriteAllBytes([System.IO.Path]::GetFullPath($OutPath), $bytes)
Write-Output "Wrote $OutPath"
