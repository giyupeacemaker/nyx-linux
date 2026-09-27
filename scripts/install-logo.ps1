#Requires -Version 5
<#
.SYNOPSIS
    Ставит логотип Nyx Linux во все места, где дистрибутив опознаётся.

.DESCRIPTION
    Исходник — 16602348272-4.svg: кот в пиксель-арте, 96 путей, прозрачный фон,
    без анимации и без встроенного растра. Радуги в нём нет, она достраивается.

    Из одного исходника делается три файла:

      nyx-mark.svg   вся композиция, радуга + кот, прозрачный фон
      nyx-icon.svg   квадрат для мест, где нужен квадрат: иконка в списке шагов
      (в branding)  logo.svg и logo-wide.svg

    Радуга достраивается шестью полосами слева, для чего viewBox расширяется
    влево. Правый край полос ступенчатый: каждая полоса длиннее следующей, плюс
    отдельный прямоугольник-холст. Это даёт диагональный срез, как в оригинальном
    нян кэте.

    Кадрирование иконки задаётся viewBox самого файла, а не сдвигом в CSS.
    Раньше смещения считались руками, и дважды оказывались мимо холста: масштаб
    зависит от ширины, которую задаёшь сам, поэтому прикидка на глаз не годится.
    Границы головы измерены по снимку: x 52.81..92.41, y 17.17..54.55.

    Все файлы самодостаточны. Внешняя ссылка на файл в SVG не годится: Qt
    считает её риском безопасности и не рисует ничего, то есть в установщике
    была бы дыра.
#>
[CmdletBinding()]
param(
    [string]$SourceSvg = '',
    [string]$OutDir    = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$project = 'C:\Users\giyu\Documents\Проект по умолчанию'
if ([string]::IsNullOrWhiteSpace($OutDir))    { $OutDir    = Join-Path $project 'config\logo' }
if ([string]::IsNullOrWhiteSpace($SourceSvg)) { $SourceSvg = Join-Path $OutDir 'nyancat.svg' }

function Say($msg) { Write-Host $msg }

if (-not (Test-Path -LiteralPath $SourceSvg)) { Say "НЕТ ФАЙЛА: $SourceSvg"; exit 1 }
if (-not (Test-Path -LiteralPath $OutDir))    { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$text = [IO.File]::ReadAllText($SourceSvg, [Text.Encoding]::UTF8)

# Числа в SVG обязаны печататься с точкой. Оператор -f и [Math]::Round берут
# локаль машины, а она русская, и {-66} сходит как -66,0000. SVG такой литерал не
# понимает: координаты молча не применяются, и полосы радуги просто не рисуются,
# без всякой ошибки. Поэтому всё, что попадает в файл, идёт через инвариантную
# культуру.
$inv = [System.Globalization.CultureInfo]::InvariantCulture
function Num([double]$v, [int]$digits = 4) { return $v.ToString("F$digits", $inv) }

# Проверка на будущее: если в локали десятичная запятая, обычный -f врёт.
if ((1.5).ToString('F1', $inv) -ne '1.5') { Say "Инвариантная культура недоступна, стоп."; exit 1 }

# --- проверки исходника -----------------------------------------------------
# Каждая из них означала бы пустой логотип в установщике, и заметить это можно
# было бы только глазами на экране установки.
$fail = $false
if ($text -notmatch 'xmlns="http://www\.w3\.org/2000/svg"') {
    Say "СТОРОЖНО: нет правильного xmlns. Присланный файл содержал http://w3.org, и он не рисовался вообще."; $fail = $true
}
if ($text -match 'base64|<image') { Say "СТОРОЖНО: в исходнике встроенный растр."; $fail = $true }
if ($fail) { exit 1 }

$openMatch = [regex]::Match($text, '<svg[^>]*>')
$vbMatch = [regex]::Match($openMatch.Value, 'viewBox="([^"]*)"')
if (-not $vbMatch.Success) { Say "Не нашёл viewBox в корневом <svg>."; exit 1 }
# viewBox бывает записан и через запятые, и через пробелы.
$parts = [regex]::Split($vbMatch.Groups[1].Value.Trim(), '[,\s]+') | Where-Object { $_ -ne '' }
$vx = [double]$parts[0]; $vy = [double]$parts[1]
$vw = [double]$parts[2]; $vh = [double]$parts[3]
Say ("исходник: {0} байт, viewBox {1} -> {2}x{3}, path={4}" -f `
    (Get-Item $SourceSvg).Length, $vbMatch.Groups[1].Value, $vw, $vh, ([regex]::Matches($text, '<path')).Count)

# --- радуга -----------------------------------------------------------------
$COLOURS = @('#ff0000', '#ff9900', '#ffff00', '#33ff00', '#0099ff', '#6633ff')
$TAIL = 66.0                       # ширина шлейфа
$BAND = ($vh * 0.50) / $COLOURS.Count
$MAIN = 40.0                       # длина основной части полосы
$STEP = $TAIL - $MAIN
$y0 = $vy + ($vh - $BAND * $COLOURS.Count) / 2.0

$rainbow = New-Object System.Text.StringBuilder
[void]$rainbow.AppendLine('')
[void]$rainbow.AppendLine('  <g id="rainbow" shape-rendering="crispEdges">')
for ($i = 0; $i -lt $COLOURS.Count; $i++) {
    $y = $y0 + $i * $BAND
    [void]$rainbow.AppendLine(('    <rect x="' + (Num ($vx - $TAIL)) + '" y="' + (Num $y) +
        '" width="' + (Num $MAIN) + '" height="' + (Num $BAND) + '" fill="' + $COLOURS[$i] + '" />'))
    if ($i -lt $COLOURS.Count - 1) {
        [void]$rainbow.AppendLine(('    <rect x="' + (Num ($vx - $TAIL + $MAIN)) + '" y="' + (Num ($y + $BAND)) +
            '" width="' + (Num $STEP) + '" height="' + (Num $BAND) + '" fill="' + $COLOURS[$i] + '" />'))
    }
}
[void]$rainbow.Append('  </g>')

# --- пересборка корневого тега ----------------------------------------------
# Старые width и height выбрасываются: если дописать новые рядом, получатся
# повторы атрибутов, а это жёсткая ошибка XML, файл просто перестаёт парситься.
$openEnd = $text.IndexOf('>', $text.IndexOf('<svg'))
$newOpen = $text.Substring($text.IndexOf('<svg'), $openEnd - $text.IndexOf('<svg'))
$newOpen = $newOpen -replace '\s*width="[^"]*"',  ''
$newOpen = $newOpen -replace '\s*height="[^"]*"', ''
$newOpen = $newOpen -replace 'viewBox="[^"]*"', ('viewBox="' + (Num ($vx - $TAIL)) + ',' + (Num $vy) + ',' + (Num ($vw + $TAIL)) + ',' + (Num $vh) + '"')
$newOpen += (' width="' + (Num ($vw + $TAIL)) + '" height="' + (Num $vh) + '">')

# Тело — всё между корневым <svg> и его последним </svg>. Радуга вставляется
# сразу после открывающего тега, а не в конец: в SVG порядок документа решает,
# что поверх чего, и шлейф в конце перекрыл бы кота вместо того, чтобы уйти под
# него. Закрывающий '>' возвращается явно: без него файл не разбирается вовсе.
$bodyStart = $openEnd + 1
$bodyEnd = $text.LastIndexOf('</svg>')
$body = $text.Substring($bodyStart, $bodyEnd - $bodyStart)

$markText = $text.Substring(0, $text.IndexOf('<svg')) + $newOpen + "`n" + `
            $rainbow.ToString() + "`n" + $body + "`n</svg>`n"

# Порядок важен: радуга вставляется сразу после открывающего тега, поэтому
# оказывается под всем содержимым, включая хвост. Иначе шлейф перекроет кота.
$mark = Join-Path $OutDir 'nyx-mark.svg'
[IO.File]::WriteAllText($mark, $markText, (New-Object System.Text.UTF8Encoding($false)))

function Test-Svg($path, $label) {
    try {
        $x = New-Object System.Xml.XmlDocument
        $x.Load($path)
        $ns = 'http://www.w3.org/2000/svg'
        $p = $x.SelectNodes("//*[local-name()='path']").Count
        $r = $x.SelectNodes("//*[local-name()='rect']").Count
        $tag = $x.DocumentElement.LocalName
        Say ("  {0,-14} {1,7:N0} байт  <{2}> path={3} rect={4}  разбирается" -f `
            $label, (Get-Item $path).Length, $tag, $p, $r)
        return $true
    } catch {
        Say ("  {0,-14} СЛОМАН: {1}" -f $label, $_.Exception.Message)
        return $false
    }
}
Say ""
Say "собрано:"
if (-not (Test-Svg $mark 'nyx-mark.svg')) { exit 1 }
Say ("  полос радуги: {0}, ступенек: {1}, высота полосы {2:F2}" -f `
    $COLOURS.Count, ($COLOURS.Count - 1), $BAND)
Say ("  новый viewBox: {0},{1},{2},{3}  (холст расширен влево на {4})" -f `
    (Num ($vx - $TAIL)), (Num $vy), (Num ($vw + $TAIL)), (Num $vh), (Num $TAIL))

# --- квадратная иконка ------------------------------------------------------
# Вся фигура кота, а не одна голова. Кот широкий, 95.44 x 57.18, поэтому в
# квадрате он занимает горизонтальную полосу, а сверху и снизу остаётся плитка.
# Это цена того, что нян-кэт узнаётся целиком: в 32 пикселя, которые занимает
# иконка в списке шагов, кот выходит мельче, чем одна голова, зато видно, что
# это поп-тарт с котом, а не просто серый кот.
#
# Границы кота измерены по снимку арта, а не прикинуты на глаз: серые пиксели
# дали x 3.31..92.41, y 17.17..54.55, а полотно арта — 0..57.18 по вертикали.
$CAT_X0 = 0.0;  $CAT_X1 = 95.44
$CAT_Y0 = 0.0;  $CAT_Y1 = 57.18
$ISIDE = [Math]::Round($CAT_X1 - $CAT_X0, 2)
$ix = [Math]::Round($CAT_X0, 2)
$iy = [Math]::Round((($CAT_Y0 + $CAT_Y1) / 2) - $ISIDE / 2, 2)
Say ""
Say ("иконка: кот целиком, {0}x{1} -> viewBox {2} {3} {4} {4}" -f `
    (Num ($CAT_X1 - $CAT_X0) 2), (Num ($CAT_Y1 - $CAT_Y0) 2), (Num $ix 2), (Num $iy 2), (Num $ISIDE 2))

# Тело арта для встраивания: всё между корневым <svg> и его последним </svg>,
# без радуги, потому что в иконке на 32 пикселя от шлейфа остаётся тонкая полоска.
$body = $markText
$bodyOpen = [regex]::Match($body, '<svg[^>]*>')
$inner = $body.Substring($bodyOpen.Index + $bodyOpen.Length)
$inner = $inner.Substring(0, $inner.LastIndexOf('</svg>'))
$inner = $inner -replace '(?s)<g id="rainbow".*?</g>', ''

$TILE = 320
$RADIUS = 45          # 14% от 320, тот же коэффициент, что и у первого логотипа
$iconText = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Nyan Cat, square, for the places that need a square: the step list icon in the
  installer, the launcher entry, the login screen.

  Generated by scripts\install-logo.ps1 from nyancat.svg.

  The whole cat is used, not just the head. The cat is 95.4 x 57.2, so it does
  not fit a square and ends up as a band across the middle with the tile above
  and below. That is the price of the whole character being recognisable: at the
  32 pixels the step list allows, the cat is smaller than a head alone would be,
  but you can see it is a pop-tart with a cat and not just a grey cat.

  The crop is expressed as a viewBox on the artwork itself: a CSS offset was
  tried and miscalculated twice, because the scale depends on the width one sets
  oneself.

  The tile is not decoration. The artwork has a transparent background, and the
  logo is mostly pale, so on the installer's light sidebar it would disappear
  without something dark under it.
-->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $TILE $TILE" width="$TILE" height="$TILE">
  <rect x="0" y="0" width="$TILE" height="$TILE" rx="$RADIUS" ry="$RADIUS" fill="#003366" />
  <svg x="0" y="0" width="$TILE" height="$TILE" viewBox="$(Num $ix 2) $(Num $iy 2) $(Num $ISIDE 2) $(Num $ISIDE 2)">$inner</svg>
</svg>
"@
$icon = Join-Path $OutDir 'nyx-icon.svg'
[IO.File]::WriteAllText($icon, $iconText, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Svg $icon 'nyx-icon.svg')) { exit 1 }

# =============================================================================
# Вшивка
# =============================================================================
$brand = Join-Path $project 'config\calamares\branding\archlinux'
if (-not (Test-Path -LiteralPath $brand)) { Say "НЕТ КАТАЛОГА: $brand"; exit 1 }

# Тело иконки для встраивания в welcome.svg: квадратное, с плиткой.
$iconBody = $iconText
$io = [regex]::Match($iconBody, '<svg[^>]*>')
$innerIcon = $iconBody.Substring($io.Index + $io.Length)
$innerIcon = $innerIcon.Substring(0, $innerIcon.LastIndexOf('</svg>'))

# Тело широкой композиции для водяного знака на фоне: без плитки и без радуги.
$innerMark = $markText
$mo = [regex]::Match($innerMark, '<svg[^>]*>')
$innerMark = $innerMark.Substring($mo.Index + $mo.Length)
$innerMark = $innerMark.Substring(0, $innerMark.LastIndexOf('</svg>'))

Say ""
Say "вшивка в branding:"

# 1. Иконка списка шагов. Имя logo.svg сохранено, поэтому productIcon в
#    branding.desc править не нужно.
Copy-Item -LiteralPath $icon -Destination (Join-Path $brand 'logo.svg') -Force
Say "  logo.svg        <- productIcon, квадрат с головой кота"

# 2. Полная композиция для productLogo. Отдельный файл: списку шагов нужен
#    квадрат, а шапке приветствия хватает места на всю картинку.
$wideOut = Join-Path $brand 'logo-wide.svg'
[IO.File]::WriteAllText($wideOut, $markText, (New-Object System.Text.UTF8Encoding($false)))
$wb = [regex]::Match([IO.File]::ReadAllText($wideOut), 'viewBox="([^"]*)"').Groups[1].Value
Say ("  logo-wide.svg   <- productLogo, вся композиция, viewBox {0}" -f $wb)

# 3. Экран приветствия. Файл собирается целиком, а не правится на месте: правка
#    на месте не идемпотентна, и после ручной правки скрипт перестал бы
#    обновлять логотип, сообщив об этом усыхающим «не тронут».
$welcomeText = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Installer welcome screen. Generated by scripts\install-logo.ps1; edit that
  script, not this file, or the next run will overwrite the change.

  The logo is inlined rather than referenced. Qt treats an external file
  reference in SVG as a security risk and renders nothing, which would leave a
  hole in the middle of the first screen the user sees.
-->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 420">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#20242b"/><stop offset="1" stop-color="#111318"/></linearGradient>
    <radialGradient id="glow"><stop stop-color="#64748b" stop-opacity=".16"/><stop offset="1" stop-color="#64748b" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="960" height="420" rx="28" fill="url(#bg)"/>
  <circle cx="170" cy="180" r="250" fill="url(#glow)"/>
  <svg x="54" y="50" width="320" height="320" viewBox="0 0 320 320">$innerIcon</svg>
  <text x="430" y="170" fill="#f3f4f6" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="56" font-weight="700">Nyx Linux</text>
  <text x="434" y="220" fill="#c4b5fd" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="25">Comfy · Gaming · Bloatless</text>
  <text x="434" y="266" fill="#9ca3af" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="18">Arch-based · UEFI · Calamares</text>
</svg>
"@
$welcome = Join-Path $brand 'welcome.svg'
[IO.File]::WriteAllText($welcome, $welcomeText, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Svg $welcome 'welcome.svg')) { exit 1 }

# 4. Фон окна установщика. Водяной знак: он под каждым окном каждого шага, и
#    в полную силу начинает спорить с текстом страницы, а это единственная
#    работа, которую фон выполнять не должен.
$wallText = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Installer window background. Generated by scripts\install-logo.ps1.

  The logo is a watermark at low opacity under the glows. This file sits behind
  every page of every step, so the mark has to stay quiet.
-->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <radialGradient id="a"><stop stop-color="#334155" stop-opacity=".32"/><stop offset="1" stop-color="#20242b" stop-opacity="0"/></radialGradient>
    <radialGradient id="b"><stop stop-color="#4c1d95" stop-opacity=".20"/><stop offset="1" stop-color="#111318" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="1920" height="1080" fill="#111318"/>
  <g opacity="0.10"><svg x="300" y="330" width="1320" height="468" viewBox="-66 0 161.64443 57.33347">$innerMark</svg></g>
  <ellipse cx="480" cy="420" rx="700" ry="700" fill="url(#a)"/>
  <ellipse cx="1450" cy="650" rx="700" ry="700" fill="url(#b)"/>
</svg>
"@
$wall = Join-Path $brand 'wallpaper.svg'
[IO.File]::WriteAllText($wall, $wallText, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Svg $wall 'wallpaper.svg')) { exit 1 }

# 5. branding.desc: productLogo на широкую композицию. Пишется безусловно,
#    чтобы второй прогон был no-op, а не жалобой, и чтобы ручная правка этой
#    строки не пережила перегенерацию.
$desc = Join-Path $brand 'branding.desc'
if (Test-Path -LiteralPath $desc) {
    $d = [IO.File]::ReadAllText($desc, [Text.Encoding]::UTF8)
    $d2 = $d -replace '(?m)^(\s*productLogo:\s*)"[^"]*"', ('$1"logo-wide.svg"')
    [IO.File]::WriteAllText($desc, $d2, (New-Object System.Text.UTF8Encoding($false)))
    if ($d2 -eq $d) { Say "  branding.desc   <- productLogo уже указывал на logo-wide.svg" }
    else             { Say "  branding.desc   <- productLogo переключён на logo-wide.svg" }
    if ($d2 -notmatch 'productIcon:\s*"logo\.svg"') {
        Say "  ВНИМАНИЕ: productIcon указывает не на logo.svg, проверь branding.desc вручную."
    }
}

Say ""
Say "Осталось отдельным шагом: экран входа SDDM, обои системы, меню загрузки."
Say "Это растр, а SVG надо сначала отрисовать."
