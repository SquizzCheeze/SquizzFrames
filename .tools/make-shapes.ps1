# Generates the resource point shape images in Media\Shapes.
#
# One image per shape: white where drawn, transparent outside, anti-aliased in
# the alpha channel only. ResourceBar.lua uses each as a MASK over a point's
# fill and its empty background, so the point is cut to the shape and still
# fills (the fill has to stay a StatusBar -- see ResourceBar.lua's header on
# secret power values). Each shape fills its square as far as its aspect
# allows and is centred, so tall shapes (the bottles) leave space at the sides.
#
# Adapted from Squizzumables' .claude\make-shapes.ps1, which draws the same
# first six shapes for its Cooldown Manager icons. Only the plain fill image is
# needed here -- no glow or proc sheets.
#
#   powershell -ExecutionPolicy Bypass -File .tools\make-shapes.ps1 [-SheetPath preview.png]
#
# -SheetPath writes a preview: every shape filled, then the same shapes half
# full, drawn over a dark background, to check them by eye.
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\Media\Shapes'),
    [string]$SheetPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size = 128
$Pad  = 2.0    # room for the anti-aliased edge

function PF([double]$x, [double]$y) {
    New-Object System.Drawing.PointF ([single]$x), ([single]$y)
}

function Polygon([System.Drawing.PointF[]]$pts) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddPolygon($pts)
    $p
}

# $points vertices on the outer radius, alternating with as many on the inner
# radius when $rInner is non-zero. The first vertex points straight up.
function Radial([int]$points, [double]$rOuter, [double]$rInner) {
    $list  = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    $steps = if ($rInner) { $points * 2 } else { $points }
    for ($i = 0; $i -lt $steps; $i++) {
        $r = if ($rInner -and ($i % 2)) { $rInner } else { $rOuter }
        $a = -[Math]::PI / 2 + $i * 2 * [Math]::PI / $steps
        $list.Add((PF ($r * [Math]::Cos($a)) ($r * [Math]::Sin($a))))
    }
    $list.ToArray()
}

# Adds a rounded rectangle as its own closed figure.
function Add-RoundRect([System.Drawing.Drawing2D.GraphicsPath]$p, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $d = 2 * $r
    $p.StartFigure()
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
}

# Several overlapping figures in one path fill as their UNION under the
# Winding rule (the default Alternate rule would punch holes where they
# overlap), which is how the bottles are built from simple parts.
function New-UnionPath {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
    $p
}

# A copy of the path, scaled to fit a $box-sized square (aspect kept) and
# centred on ($cx, $cy).
function Fit([System.Drawing.Drawing2D.GraphicsPath]$src, [double]$box, [double]$cx, [double]$cy) {
    $path = $src.Clone()
    $b = $path.GetBounds()
    $scale = [Math]::Min($box / $b.Width, $box / $b.Height)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    # Matrix calls prepend, so these apply bottom-up: centre on the origin,
    # scale, then move into place.
    $m.Translate($cx, $cy)
    $m.Scale($scale, $scale)
    $m.Translate(-($b.X + $b.Width / 2), -($b.Y + $b.Height / 2))
    $path.Transform($m)
    $path
}

function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    return @{ Bitmap = $bmp; Graphics = $g }
}

# White wherever anything was drawn, black where nothing was; alpha untouched.
# So a tint gets no dark fringe, and the mask still works if read by colour.
function Finish($canvas) {
    $canvas.Graphics.Dispose()
    $bmp   = $canvas.Bitmap
    $rect  = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data  = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, $bmp.PixelFormat)
    $n     = $data.Stride * $bmp.Height
    $bytes = New-Object byte[] $n
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $n)
    for ($i = 0; $i -lt $n; $i += 4) {
        $v = if ($bytes[$i + 3] -gt 0) { 255 } else { 0 }
        $bytes[$i] = $v; $bytes[$i + 1] = $v; $bytes[$i + 2] = $v
    }
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $n)
    $bmp.UnlockBits($data)
    $bmp
}

function Render-Fill([System.Drawing.Drawing2D.GraphicsPath]$src) {
    $c = New-Canvas $Size $Size
    $path = Fit $src ($Size - 2 * $Pad) ($Size / 2) ($Size / 2)
    $c.Graphics.FillPath([System.Drawing.Brushes]::White, $path)
    Finish $c
}

# ---------------------------------------------------------------------------
# Border rings: the point border on shapes. One image per shape per thickness,
# named <shape>-border<n>.png, n = 1..$BorderWidths.Count.
#
# A ring is the part of the shape within $width pixels (of this 128 px image)
# of its edge. Its OUTER edge is therefore exactly the mask's edge, so it sits
# inside the point, drawn over the fill, and the point keeps its size.
#
# Built from a distance transform of the filled shape, NOT by stroking the
# path: the bottles are unions of overlapping figures, and a stroke draws every
# figure's own outline -- seams across the inside of the bottle included.
# Rendered at $SS times the size and averaged down, so both edges of the ring
# are anti-aliased.
# ---------------------------------------------------------------------------
$SS = 4
# Topped out at 16: any thicker and the bottle necks and the star's middle
# fill in solid, and the ring stops reading as an outline.
$BorderWidths = @(5, 8, 12, 16)

Add-Type -TypeDefinition @'
public static class SquizzRing
{
    const double INF = 1e20;

    public static byte[] AlphaOf(byte[] bgra, int count)
    {
        byte[] a = new byte[count];
        for (int i = 0; i < count; i++) a[i] = bgra[i * 4 + 3];
        return a;
    }

    // Felzenszwalb & Huttenlocher's 1D squared distance transform.
    static void Edt1(double[] f, int n, double[] d, int[] v, double[] z)
    {
        int k = 0;
        v[0] = 0; z[0] = -INF; z[1] = INF;
        for (int q = 1; q < n; q++)
        {
            double s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
            while (s <= z[k])
            {
                k--;
                s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
            }
            k++;
            v[k] = q; z[k] = s; z[k + 1] = INF;
        }
        k = 0;
        for (int q = 0; q < n; q++)
        {
            while (z[k + 1] < q) k++;
            d[q] = (q - v[k]) * (q - v[k]) + f[v[k]];
        }
    }

    // alpha: n*n supersampled coverage. Returns BGRA for (n/ss)^2 pixels,
    // white, with the ring as alpha.
    public static byte[] Make(byte[] alpha, int n, double width, int ss)
    {
        double[] f = new double[n * n];
        for (int i = 0; i < n * n; i++) f[i] = alpha[i] >= 128 ? INF : 0;

        double[] col = new double[n], d = new double[n], z = new double[n + 1];
        int[] v = new int[n];
        for (int x = 0; x < n; x++)
        {
            for (int y = 0; y < n; y++) col[y] = f[y * n + x];
            Edt1(col, n, d, v, z);
            for (int y = 0; y < n; y++) f[y * n + x] = d[y];
        }
        for (int y = 0; y < n; y++)
        {
            for (int x = 0; x < n; x++) col[x] = f[y * n + x];
            Edt1(col, n, d, v, z);
            for (int x = 0; x < n; x++) f[y * n + x] = d[x];
        }

        int m = n / ss;
        double w2 = width * width;
        byte[] outPx = new byte[m * m * 4];
        for (int oy = 0; oy < m; oy++)
        for (int ox = 0; ox < m; ox++)
        {
            int hits = 0;
            for (int sy = 0; sy < ss; sy++)
            for (int sx = 0; sx < ss; sx++)
            {
                int i = (oy * ss + sy) * n + (ox * ss + sx);
                if (alpha[i] >= 128 && f[i] < w2) hits++;
            }
            int o = (oy * m + ox) * 4;
            outPx[o] = 255; outPx[o + 1] = 255; outPx[o + 2] = 255;
            outPx[o + 3] = (byte)(hits * 255 / (ss * ss));
        }
        return outPx;
    }
}
'@

function Render-Border([System.Drawing.Drawing2D.GraphicsPath]$src, [double]$width) {
    $big = $Size * $SS
    $c = New-Canvas $big $big
    $path = Fit $src ($big - 2 * $Pad * $SS) ($big / 2) ($big / 2)
    $c.Graphics.FillPath([System.Drawing.Brushes]::White, $path)
    $c.Graphics.Dispose()

    $src32 = $c.Bitmap
    $rect  = New-Object System.Drawing.Rectangle 0, 0, $big, $big
    $data  = $src32.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $src32.PixelFormat)
    $bytes = New-Object byte[] ($data.Stride * $big)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $src32.UnlockBits($data)

    $alpha  = [SquizzRing]::AlphaOf($bytes, $big * $big)
    $pixels = [SquizzRing]::Make($alpha, $big, $width * $SS, $SS)

    $bmp  = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
    $bmp.UnlockBits($data)
    $bmp
}

# ---------------------------------------------------------------------------
# The shapes. Units are arbitrary; Fit scales each to the image. The first six
# match Squizzumables' shapes, so the two addons' icons and points agree.
# ---------------------------------------------------------------------------
$shapes = [ordered]@{}

$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddEllipse(0, 0, 100, 100)
$shapes['circle'] = $p

$shapes['diamond'] = Polygon @((PF 50 0), (PF 100 50), (PF 50 100), (PF 0 50))

# Point-up, so it fills the height.
$shapes['hexagon'] = Polygon (Radial 6 50 0)

# Fatter than a true pentagram so it reads at small sizes.
$shapes['star'] = Polygon (Radial 5 50 25)

# Heater shield: flat top, straight sides, curving in to a point.
$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddLine(0, 0, 100, 0)
$p.AddLine(100, 0, 100, 50)
$p.AddBezier(100, 50, 100, 85, 75, 102, 50, 118)
$p.AddBezier(50, 118, 25, 102, 0, 85, 0, 50)
$p.CloseFigure()
$shapes['shield'] = $p

# The classic parametric heart, y flipped so the point is at the bottom.
$pts = for ($i = 0; $i -lt 240; $i++) {
    $t = 2 * [Math]::PI * $i / 240
    $x = 16 * [Math]::Pow([Math]::Sin($t), 3)
    $y = -(13 * [Math]::Cos($t) - 5 * [Math]::Cos(2 * $t) - 2 * [Math]::Cos(3 * $t) - [Math]::Cos(4 * $t))
    PF $x $y
}
$shapes['heart'] = Polygon $pts

# Potion: a round-bottomed flask. Ball body, a short neck, and a wider cork on
# top so it reads as a stoppered bottle rather than a lollipop.
$p = New-UnionPath
$p.AddEllipse(8, 38, 84, 84)
$p.StartFigure(); $p.AddRectangle((New-Object System.Drawing.RectangleF 38, 16, 24, 32))
Add-RoundRect $p 32 4 36 16 4
$shapes['potion'] = $p

# Bottle: tall body with sloped shoulders into a long neck and a lip.
$p = New-UnionPath
Add-RoundRect $p 22 52 56 76 10
$p.StartFigure(); $p.AddPolygon(@((PF 40 34), (PF 60 34), (PF 78 62), (PF 22 62)))
$p.StartFigure(); $p.AddRectangle((New-Object System.Drawing.RectangleF 40, 10, 20, 32))
Add-RoundRect $p 37 2 26 12 3
$shapes['bottle'] = $p

# Nail polish: a squat, square-shouldered bottle under a tall brush cap, with
# a narrow collar between them.
$p = New-UnionPath
Add-RoundRect $p 14 52 72 60 12
$p.StartFigure(); $p.AddRectangle((New-Object System.Drawing.RectangleF 34, 44, 32, 12))
Add-RoundRect $p 38 0 24 48 5
$shapes['nailpolish'] = $p

# Holy Power rune 1, traced by eye from Blizzard's "uf-holypower-rune1-active"
# as it renders in game (2026-09-17 reference screenshots).
#
# APPROXIMATE, and knowingly so. The atlas is a hand-painted glyph roughly 34px
# wide on screen, so its tapers and curve tensions cannot be recovered exactly;
# these control points reproduce the READ of the glyph -- a thick crescent hook
# falling from a point at top right, curving down and left, then flaring right
# along the bottom into a pointed tail -- not its every contour.
#
# Drawn as one closed outline (outer edge out, inner edge back) rather than a
# stroked centreline: a filled path is what Render-Fill and the distance-
# transform border generator both expect, and it keeps the taper under direct
# control instead of at the mercy of a pen width.
# NOTE: the Holy Power runes are NOT drawn here. They come in as supplied art
# (white silhouette on transparency, 512 px = $Size * $SS, so the ring
# generator can consume them directly) and are processed by
# .tools\make-image-shapes.ps1 instead.
#
# Three attempts to trace rune 1 procedurally all failed -- a crescent, then a
# ribbon, then a sickle -- because these are hand-painted glyphs with tapers
# and curve tensions that cannot be recovered by eye from a ~34 px reference.
# Do not re-add a $shapes['holyrune*'] entry here: this script writes
# <name>.png, so an entry of that name would silently overwrite the real art
# on the next run.

# ---------------------------------------------------------------------------
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null

$fills   = [ordered]@{}
$borders = [ordered]@{}
foreach ($name in $shapes.Keys) {
    $fills[$name] = Render-Fill $shapes[$name]
    $fills[$name].Save((Join-Path $OutDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $borders[$name] = @()
    for ($n = 1; $n -le $BorderWidths.Count; $n++) {
        $ring = Render-Border $shapes[$name] $BorderWidths[$n - 1]
        $ring.Save((Join-Path $OutDir "$name-border$n.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $borders[$name] += , $ring
    }
    Write-Output "wrote $name (+ $($BorderWidths.Count) borders)"
}

# ---------------------------------------------------------------------------
# Supplied art. Silhouettes we did not draw, dropped into .tools\art as
# <name>.png and given exactly the same treatment as a procedural shape -- a
# $Size fill plus the four border rings -- so nothing downstream can tell the
# two apart. ResourceBar.SHAPES just names the file.
#
# Sources are expected WHITE ON TRANSPARENCY at $Size * $SS px, which is the
# resolution Render-Border already works at internally, so the ring generator
# consumes their alpha with no resampling at all. Anything else is rescaled to
# that first, which costs a little edge quality.
#
# The preview sheet below deliberately covers only the procedural shapes: it
# exists to check geometry this script DREW, and supplied art is checked by
# looking at the art.
# ---------------------------------------------------------------------------
$ArtDir = Join-Path $PSScriptRoot 'art'
if (Test-Path $ArtDir) {
    $big = $Size * $SS
    foreach ($srcFile in (Get-ChildItem $ArtDir -Filter '*.png' | Sort-Object Name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($srcFile.Name)
        $img  = New-Object System.Drawing.Bitmap $srcFile.FullName

        $work = New-Object System.Drawing.Bitmap $big, $big, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gw = [System.Drawing.Graphics]::FromImage($work)
        $gw.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gw.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gw.DrawImage($img, 0, 0, $big, $big)
        $gw.Dispose(); $img.Dispose()

        $rectBig = New-Object System.Drawing.Rectangle 0, 0, $big, $big
        $data  = $work.LockBits($rectBig, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $big)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $work.UnlockBits($data)
        $alpha = [SquizzRing]::AlphaOf($bytes, $big * $big)

        # Fill: down to $Size, then every drawn pixel forced to pure white --
        # the same guarantee Finish gives the procedural shapes, so a tint gets
        # no dark fringe from the source art's own colour.
        $rectOut = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
        $fill = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gf = [System.Drawing.Graphics]::FromImage($fill)
        $gf.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gf.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gf.DrawImage($work, 0, 0, $Size, $Size)
        $gf.Dispose()
        $fd = $fill.LockBits($rectOut, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, $fill.PixelFormat)
        $fb = New-Object byte[] ($fd.Stride * $Size)
        [System.Runtime.InteropServices.Marshal]::Copy($fd.Scan0, $fb, 0, $fb.Length)
        for ($i = 0; $i -lt $fb.Length; $i += 4) {
            if ($fb[$i + 3] -gt 0) { $fb[$i] = 255; $fb[$i + 1] = 255; $fb[$i + 2] = 255 }
        }
        [System.Runtime.InteropServices.Marshal]::Copy($fb, 0, $fd.Scan0, $fb.Length)
        $fill.UnlockBits($fd)
        $fill.Save((Join-Path $OutDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $fill.Dispose()

        for ($n = 1; $n -le $BorderWidths.Count; $n++) {
            $pixels = [SquizzRing]::Make($alpha, $big, ($BorderWidths[$n - 1] * $SS), $SS)
            $ring = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $rd = $ring.LockBits($rectOut, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $ring.PixelFormat)
            [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $rd.Scan0, $pixels.Length)
            $ring.UnlockBits($rd)
            $ring.Save((Join-Path $OutDir "$name-border$n.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            $ring.Dispose()
        }
        $work.Dispose()
        Write-Output "wrote $name from art (+ $($BorderWidths.Count) borders)"
    }
}

# A white image drawn in one colour.
function Tint([double]$cr, [double]$cg, [double]$cb) {
    $m = New-Object System.Drawing.Imaging.ColorMatrix
    $m.Matrix00 = [single]$cr; $m.Matrix11 = [single]$cg; $m.Matrix22 = [single]$cb
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($m)
    , $ia
}

if ($SheetPath) {
    $cell  = 150
    # Rows 3 and 4: a grey point with the thinnest and thickest gold border.
    $sheet = New-Object System.Drawing.Bitmap ($cell * $fills.Count), ($cell * 4)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 40, 40, 40))
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $i = 0
    foreach ($name in $fills.Keys) {
        $x = $i * $cell + ($cell - $Size) / 2
        $y = ($cell - $Size) / 2
        $g.DrawImage($fills[$name], [int]$x, [int]$y, $Size, $Size)
        # Second row: the bottom half only, like a point half filled from the
        # bottom up.
        $src = New-Object System.Drawing.Rectangle 0, ($Size / 2), $Size, ($Size / 2)
        $dst = New-Object System.Drawing.Rectangle ([int]$x), ([int]($cell + $y + $Size / 2)), $Size, ($Size / 2)
        $g.DrawImage($fills[$name], $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)
        $grey = Tint 0.35 0.35 0.35
        $gold = Tint 1 0.8 0.2
        $rows = @(@(2, 0), @(3, ($BorderWidths.Count - 1)))
        foreach ($row in $rows) {
            $dst = New-Object System.Drawing.Rectangle ([int]$x), ([int]($cell * $row[0] + $y)), $Size, $Size
            $g.DrawImage($fills[$name], $dst, 0, 0, $Size, $Size, [System.Drawing.GraphicsUnit]::Pixel, $grey)
            $g.DrawImage($borders[$name][$row[1]], $dst, 0, 0, $Size, $Size, [System.Drawing.GraphicsUnit]::Pixel, $gold)
        }
        $i++
    }
    $g.Dispose()
    $sheet.Save([System.IO.Path]::GetFullPath($SheetPath), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "wrote $SheetPath"
}
