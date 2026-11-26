# hw kit - Phase C manual checklist. Answers: y = OK, n = problem, s = skipped.

function Open-Manual([string]$mode) {
  $page = Join-Path $script:KIT 'stress\manual.html'
  $br = Find-Browser
  $uri = 'file:///' + ($page -replace '\\', '/') + "?mode=$mode"
  if ($br) { Start-Process -FilePath $br -ArgumentList "--new-window --start-fullscreen `"$uri`"" } else { Start-Process $uri }
}

function Run-Manual($R, $M) {
  $isLaptop = ($R.id.chassis -eq 'laptop')
  $items = @(
    @{ k = 'pixels'; t = 'Screen: no dead or stuck pixels, no lines, no backlight bleed'; s = 'screen'; lvl = 'AMBER'; neg = 'Screen defect: cost of a panel replacement'; open = 'pixels'; laptop = $true },
    @{ k = 'keys'; t = 'Keyboard: every key lit up green'; s = 'keyboard'; lvl = 'AMBER'; neg = 'Faulty keys: cost of a keyboard replacement'; open = 'keys'; laptop = $true },
    @{ k = 'sound'; t = 'Speakers: left and right both play cleanly'; s = 'speakers'; lvl = 'AMBER'; neg = ''; open = 'sound'; laptop = $true },
    @{ k = 'touchpad'; t = 'Touchpad: moves, clicks, two-finger scroll'; s = 'touchpad'; lvl = 'AMBER'; neg = ''; laptop = $true },
    @{ k = 'webcam'; t = 'Webcam works (open the Camera app)'; s = 'webcam'; lvl = 'AMBER'; neg = ''; laptop = $true },
    @{ k = 'ports'; t = 'Every USB / USB-C / HDMI port works (plug your stick or phone into each)'; s = 'ports'; lvl = 'AMBER'; neg = 'Dead port: ask for a discount'; laptop = $false },
    @{ k = 'charger'; t = 'Charger is original brand and its watts match the laptop label'; s = 'charger'; lvl = 'AMBER'; neg = 'Non-original charger: cost of a genuine one'; laptop = $true },
    @{ k = 'hinge'; t = 'Hinge firm, no cracks; lid closes evenly (no gap = no swollen battery)'; s = 'hinge/battery swell'; lvl = 'RED'; neg = ''; laptop = $true },
    @{ k = 'screws'; t = 'Screws and stickers look untouched (no stripped screws, no re-stuck labels)'; s = 'tamper'; lvl = 'AMBER'; neg = ''; laptop = $false },
    @{ k = 'gpu_label'; t = 'TOWER: side panel open, graphics card label matches the claim, no dust caked / burnt smell'; s = 'gpu label'; lvl = 'RED'; neg = ''; laptop = $null },
    @{ k = 'psu'; t = 'TOWER: power supply is a known brand, watts on its label (photo it)'; s = 'psu'; lvl = 'AMBER'; neg = 'Unbranded PSU: cost of a decent one'; laptop = $null }
  )
  Say ''
  Say 'PHASE C - manual checks. Answer y (OK), n (problem) or s (skip).' 'Cyan'
  foreach ($it in $items) {
    if ($it.laptop -eq $true -and -not $isLaptop) { continue }
    if ($null -eq $it.laptop -and $isLaptop) { continue }
    if ($it.open) { Open-Manual $it.open }
    $a = ''
    if ($script:RUNAUTO) { $a = 's' } else { while ($a -notin @('y', 'n', 's')) { $a = (Read-Host ("  " + $it.t + " (y/n/s)")).Trim().ToLower() } }
    $M[$it.k] = @{ answer = $a; text = ($it.t + ': NO'); text_short = $it.s; level = $it.lvl; negotiate = $it.neg }
  }
  Say ''
  Say '  Paperwork and locks:' 'Cyan'
  $M.sticker_serial = Ask '  Serial number printed on the sticker underneath (blank = skip)'
  $M.bios_password = Ask '  Does the BIOS/firmware ask for a password the seller cannot remove? (y/n)' 's'
  $M.paperwork = Ask '  Bill or written receipt with the serial number? (y/n)' 's'
  $M.gst_bill = Ask '  GST bill available? (y/n)' 's'
  $M.warranty = Ask '  Warranty months left (from the maker''s site, blank = unknown)'
  $M.keyboard_layout = Ask '  Keyboard layout (US / UK / other, blank = skip)'
  $M.done = $true
  return $M
}
