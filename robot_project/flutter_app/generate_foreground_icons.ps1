Add-Type -AssemblyName System.Drawing

$srcPath = Join-Path $PSScriptRoot "assets\images\robot_controller_logo.png"
$resBase = Join-Path $PSScriptRoot "android\app\src\main\res"

$img = [System.Drawing.Image]::FromFile($srcPath)

# Foreground adaptive icon sizes (108dp per density bucket, with 18dp safe zone padding)
# mdpi=108, hdpi=162, xhdpi=216, xxhdpi=324, xxxhdpi=432
$fgSizes = @{
    "mipmap-mdpi"    = 108
    "mipmap-hdpi"    = 162
    "mipmap-xhdpi"   = 216
    "mipmap-xxhdpi"  = 324
    "mipmap-xxxhdpi" = 432
}

foreach ($entry in $fgSizes.GetEnumerator()) {
    $dir  = Join-Path $resBase $entry.Key
    $file = Join-Path $dir "ic_launcher_foreground.png"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $sz  = $entry.Value
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($img, 0, 0, $sz, $sz)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Saved foreground $($entry.Key): ${sz}x${sz}"
}

$img.Dispose()
Write-Host "Foreground icons done!"
