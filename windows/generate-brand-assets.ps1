$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$assetDirectory = Join-Path $PSScriptRoot "Tvoice.Windows\Assets"
New-Item -ItemType Directory -Force -Path $assetDirectory | Out-Null

function New-TvoiceBitmap([int]$size) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $scale = $size / 108.0
    $bounds = [System.Drawing.RectangleF]::new(2 * $scale, 2 * $scale, 104 * $scale, 104 * $scale)
    $radius = 24 * $scale
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = 2 * $radius
    $path.AddArc($bounds.X, $bounds.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($bounds.Right - $diameter, $bounds.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($bounds.Right - $diameter, $bounds.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($bounds.X, $bounds.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $gradient = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        $bounds,
        [System.Drawing.ColorTranslator]::FromHtml("#1237C8"),
        [System.Drawing.ColorTranslator]::FromHtml("#0D91FF"),
        45.0)
    $graphics.FillPath($gradient, $path)

    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $tPoints = @(
        [System.Drawing.PointF]::new(34*$scale, 36*$scale), [System.Drawing.PointF]::new(66*$scale, 36*$scale),
        [System.Drawing.PointF]::new(64*$scale, 44*$scale), [System.Drawing.PointF]::new(54*$scale, 44*$scale),
        [System.Drawing.PointF]::new(48*$scale, 72*$scale), [System.Drawing.PointF]::new(38*$scale, 72*$scale),
        [System.Drawing.PointF]::new(44*$scale, 44*$scale), [System.Drawing.PointF]::new(32*$scale, 44*$scale)
    )
    $graphics.FillPolygon($white, $tPoints)

    $cyan = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml("#19C9F2"), [Math]::Max(1.5, 2.7*$scale))
    $cyan.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $cyan.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    foreach ($line in @(@(53,62,53,67), @(57,59,57,70), @(61,56,61,72), @(65,59,65,70), @(69,62,69,68), @(73,64,73,67))) {
        $graphics.DrawLine($cyan, $line[0]*$scale, $line[1]*$scale, $line[2]*$scale, $line[3]*$scale)
    }

    $cyan.Dispose(); $white.Dispose(); $gradient.Dispose(); $path.Dispose(); $graphics.Dispose()
    return $bitmap
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = foreach ($size in $sizes) {
    $bitmap = New-TvoiceBitmap $size
    $stream = [System.IO.MemoryStream]::new()
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    ,$stream.ToArray()
    $stream.Dispose()
}

$iconPath = Join-Path $assetDirectory "Tvoice.ico"
$file = [System.IO.File]::Create($iconPath)
$writer = [System.IO.BinaryWriter]::new($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for ($index = 0; $index -lt $sizes.Count; $index++) {
    $encodedSize = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
    $writer.Write([byte]$encodedSize); $writer.Write([byte]$encodedSize)
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$index].Length); $writer.Write([uint32]$offset)
    $offset += $images[$index].Length
}
foreach ($image in $images) { $writer.Write($image) }
$writer.Dispose(); $file.Dispose()

$preview = New-TvoiceBitmap 512
$preview.Save((Join-Path $assetDirectory "Tvoice.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()
