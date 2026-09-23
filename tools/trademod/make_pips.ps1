<#
  make_pips.ps1 - generate commodity pip icons as Empire-format TGA.

  WHAT I CAN AND CANNOT MAKE
    3D MODELS: no. Building models are warscape rigid models, and the only
    tooling here (etwng\rigid_model_v2) is `unpack_rmv2` - it unpacks but
    cannot repack, so there is not even a round trip for editing an existing
    model. New building art needs a modelling tool and a person. That is why
    the chain buildings reference Empire's own metalworks/pottery/port pieces.

    2D ICONS: yes. The pips are the simplest image format there is, and this
    writes them directly.

  THE FORMAT (measured from ui.pack's coffee.tga, 2,748 bytes)
    18-byte header : type 2 (uncompressed true-colour), 26x26, 32bpp,
                     descriptor 0x08 -> 8 alpha bits, origin BOTTOM-LEFT,
                     so rows are written bottom-up
    2,704 bytes    : 26 * 26 * 4, BGRA order (not RGBA)
    26-byte footer : TGA 2.0, "TRUEVISION-XFILE." - present in the shipped
                     files, so it is reproduced

  QUALITY, HONESTLY
    These are clean flat-shaded shapes with an outline and a highlight -
    readable at 26px and distinguishable from each other. They are NOT painted
    in Empire's hand-illustrated style and will look like what they are next to
    CA's own pips. They exist so every good is not the coffee icon; treat them
    as functional placeholders an artist can replace.

  Usage
    .\make_pips.ps1                     # write to the default staged pips dir
    .\make_pips.ps1 -Out <dir>
#>
param(
    [string]$Out
)

if (-not $Out) { $Out = Join-Path $env:TEMP 'etw_chain_pack\staged\ui\campaign ui\pips' }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# name, shape, body colour, accent colour
$PIPS = @(
    @('iron',          'ingot',  '#8C8C94', '#5A5A62'),
    @('timber',        'logs',   '#8B5A2B', '#5C3A1A'),
    @('grain',         'sheaf',  '#D9A441', '#9A7020'),
    @('coal',          'lump',   '#2E2E32', '#111114'),
    @('saltpetre',     'crystal','#E8E4D8', '#A8A292'),
    @('lead',          'ingot',  '#6E7A8A', '#454E59'),
    @('steel',         'bar',    '#B8C2CC', '#6E7A86'),
    @('gunpowder',     'barrel', '#4A3B2A', '#2A2118'),
    @('ammunition',    'shot',   '#C9A227', '#8A6E12'),
    @('muskets',       'musket', '#7A5230', '#3E2A18'),
    @('cannon',        'cannon', '#3A3A40', '#1C1C20'),
    @('textiles',      'bolt',   '#B5651D', '#7A4212'),
    @('uniforms',      'coat',   '#9B1B24', '#5E0F16'),
    @('naval_supplies','coil',   '#A98A5C', '#6F5836')
)

function HexBrush($hex) {
    [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($hex))
}
function HexPen($hex, $w) {
    [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml($hex), $w)
}

function Draw-Shape($g, $shape, $body, $accent) {
    $b  = HexBrush $body
    $a  = HexBrush $accent
    $pn = HexPen $accent 1.6
    $hi = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(90, 255, 255, 255))
    switch ($shape) {
        'lump'    { $g.FillEllipse($b, 3,8,13,12);  $g.FillEllipse($b, 12,5,10,10); $g.DrawEllipse($pn,3,8,13,12); $g.DrawEllipse($pn,12,5,10,10) }
        'ingot'   { $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
                    $p.AddPolygon(@([System.Drawing.Point]::new(4,17),[System.Drawing.Point]::new(8,9),[System.Drawing.Point]::new(21,9),[System.Drawing.Point]::new(17,17)))
                    $g.FillPath($b,$p); $g.DrawPath($pn,$p); $p.Dispose()
                    $g.FillRectangle($hi, 9,10,10,2) }
        'bar'     { $g.FillRectangle($b, 3,10,20,7); $g.DrawRectangle($pn,3,10,20,7); $g.FillRectangle($hi,5,11,16,2) }
        'logs'    { foreach ($y in 7,14) { $g.FillRectangle($b,3,$y,20,6); $g.DrawRectangle($pn,3,$y,20,6); $g.FillEllipse($a,2,$y,5,6) } }
        'sheaf'   { $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
                    $p.AddPolygon(@([System.Drawing.Point]::new(13,2),[System.Drawing.Point]::new(21,22),[System.Drawing.Point]::new(5,22)))
                    $g.FillPath($b,$p); $g.DrawPath($pn,$p); $p.Dispose()
                    $g.FillRectangle($a,6,16,14,2) }
        'crystal' { $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
                    $p.AddPolygon(@([System.Drawing.Point]::new(13,3),[System.Drawing.Point]::new(22,13),[System.Drawing.Point]::new(13,23),[System.Drawing.Point]::new(4,13)))
                    $g.FillPath($b,$p); $g.DrawPath($pn,$p); $p.Dispose()
                    $g.FillPolygon($hi, @([System.Drawing.Point]::new(13,5),[System.Drawing.Point]::new(19,13),[System.Drawing.Point]::new(13,13))) }
        'barrel'  { $g.FillRectangle($b,6,4,14,18); $g.DrawRectangle($pn,6,4,14,18)
                    foreach ($y in 8,17) { $g.FillRectangle($a,6,$y,14,2) }
                    $g.FillRectangle($hi,8,6,3,14) }
        'shot'    { foreach ($x in 4,11,18) { $g.FillRectangle($b,$x,9,5,11); $g.DrawRectangle($pn,$x,9,5,11); $g.FillEllipse($a,$x,6,5,6) } }
        'musket'  { $g.RotateTransform(-30); $g.TranslateTransform(-10,8)
                    $g.FillRectangle($b,2,11,22,3); $g.DrawRectangle($pn,2,11,22,3)
                    $g.FillRectangle($a,2,10,7,5); $g.ResetTransform() }
        'cannon'  { $g.FillRectangle($b,4,10,17,7); $g.DrawRectangle($pn,4,10,17,7)
                    $g.FillEllipse($a,2,8,8,11); $g.DrawEllipse($pn,2,8,8,11)
                    $g.FillRectangle($hi,7,11,11,2) }
        'bolt'    { $g.FillRectangle($b,4,6,18,14); $g.DrawRectangle($pn,4,6,18,14)
                    $g.FillEllipse($a,1,6,6,14); $g.DrawEllipse($pn,1,6,6,14) }
        'coat'    { $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
                    $p.AddPolygon(@([System.Drawing.Point]::new(9,4),[System.Drawing.Point]::new(17,4),[System.Drawing.Point]::new(21,10),[System.Drawing.Point]::new(19,22),[System.Drawing.Point]::new(7,22),[System.Drawing.Point]::new(5,10)))
                    $g.FillPath($b,$p); $g.DrawPath($pn,$p); $p.Dispose()
                    $g.FillRectangle($hi,12,5,2,17) }
        'coil'    { foreach ($r in 10,7,4) { $g.DrawEllipse((HexPen $body 2.4), 13-$r,13-$r,$r*2,$r*2) }
                    $g.DrawEllipse($pn,3,3,20,20) }
    }
    $b.Dispose(); $a.Dispose(); $pn.Dispose(); $hi.Dispose()
}

function Write-Tga($bmp, $path) {
    $w = $bmp.Width; $h = $bmp.Height
    $bytes = New-Object byte[] (18 + $w*$h*4 + 26)
    $bytes[2]  = 2                      # uncompressed true-colour
    $bytes[12] = $w -band 0xFF; $bytes[13] = ($w -shr 8) -band 0xFF
    $bytes[14] = $h -band 0xFF; $bytes[15] = ($h -shr 8) -band 0xFF
    $bytes[16] = 32                     # bpp
    $bytes[17] = 8                      # 8 alpha bits, origin bottom-left
    $i = 18
    # bottom-up rows, BGRA - matching the shipped pips exactly
    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bytes[$i++] = $c.B; $bytes[$i++] = $c.G; $bytes[$i++] = $c.R; $bytes[$i++] = $c.A
        }
    }
    $footer = [System.Text.Encoding]::ASCII.GetBytes("TRUEVISION-XFILE.")
    [Array]::Copy($footer, 0, $bytes, 18 + $w*$h*4 + 8, $footer.Length)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $bytes.Length
}

$made = 0
foreach ($p in $PIPS) {
    $bmp = New-Object System.Drawing.Bitmap 26,26
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))     # transparent
    Draw-Shape $g $p[1] $p[2] $p[3]
    $g.Dispose()
    $n = Write-Tga $bmp (Join-Path $Out ($p[0] + ".tga"))
    $bmp.Dispose()
    Write-Host ("  {0,-16} {1,-8} {2} bytes" -f $p[0], $p[1], $n)
    $made++
}
Write-Host ""
Write-Host ("wrote {0} pip(s) to {1}" -f $made, $Out) -ForegroundColor Green
Write-Host "Shipped pips are 2748 bytes - these must match to be the same format."
