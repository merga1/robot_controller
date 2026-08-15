Add-Type -AssemblyName System.Drawing

$srcPath = Join-Path $PSScriptRoot "assets\images\robot_controller_logo.png"
$resBase = Join-Path $PSScriptRoot "android\app\src\main\res"

$img = [System.Drawing.Image]::FromFile($srcPath)

$sizes = @{
    "mipmap-mdpi"    = 48
    "mipmap-hdpi"    = 72
    "mipmap-xhdpi"   = 96
    "mipmap-xxhdpi"  = 144
    "mipmap-xxxhdpi" = 192
}

foreach ($entry in $sizes.GetEnumerator()) {
    $dir  = Join-Path $resBase $entry.Key
    $file = Join-Path $dir "ic_launcher.png"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $sz  = $entry.Value
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.DrawImage($img, 0, 0, $sz, $sz)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Saved $($entry.Key): $sz x $sz -> $file"
}

# Also create a round variant (same image, Android uses ic_launcher_round for round icons)
foreach ($entry in $sizes.GetEnumerator()) {
    $dir  = Join-Path $resBase $entry.Key
    $file = Join-Path $dir "ic_launcher_round.png"
    $sz   = $entry.Value
    $bmp  = New-Object System.Drawing.Bitmap($sz, $sz)
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Clip to circle
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse(0, 0, $sz, $sz)
    $g.SetClip($path)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($img, 0, 0, $sz, $sz)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Saved $($entry.Key) (round): $sz x $sz -> $file"
}

$img.Dispose()
Write-Host ""
Write-Host "All launcher icons generated successfully!"
