# Tama Bridge flasher for Windows: finds the ESP32 on USB, recognises its chip and writes the
# matching firmware. Run flash.bat (double-click). Needs no installation.
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
$esptool = Join-Path $PSScriptRoot 'esptool\esptool.exe'

Write-Host ''
Write-Host '  Tama Bridge flasher' -ForegroundColor Magenta
Write-Host '  Plug the ESP32 in with a USB cable (a data cable, not a charge-only one).'
Write-Host '  If it is not found: hold its BOOT button while plugging it in.'
Write-Host ''

# the serial ports, newest last
$ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
if (-not $ports) {
  Write-Host '  No serial port found. Install the USB driver of your board (CP210x or CH340), then try again.' -ForegroundColor Red
  Read-Host '  Press Enter to close'
  exit 1
}
$port = $null
$chip = $null
foreach ($p in $ports) {
  Write-Host "  Trying $p ..."
  $out = & $esptool --port $p chip_id 2>&1 | Out-String
  if ($out -match 'Chip is (ESP32-C3|ESP32-S3|ESP32-C6|ESP32-S2|ESP32)') {
    $port = $p
    $chip = $Matches[1]
    break
  }
}
if (-not $port) {
  Write-Host '  No ESP32 answered. Hold BOOT, press and let go of RESET (EN), let go of BOOT, then run this again.' -ForegroundColor Red
  Read-Host '  Press Enter to close'
  exit 1
}
if ($chip -eq 'ESP32-S2') {
  Write-Host '  This is an ESP32-S2: it has no Bluetooth, so it cannot be a Tama Bridge.' -ForegroundColor Red
  Read-Host '  Press Enter to close'
  exit 1
}
# an ESP32-S3 may be a Heltec board with a screen: ask
if ($chip -eq 'ESP32-S3') {
  Write-Host ''
  Write-Host '  This is an ESP32-S3. Which board?'
  Write-Host '    1  A plain ESP32-S3 board (XIAO S3, DevKit)'
  Write-Host '    2  Heltec WiFi LoRa 32 V3 (with screen)'
  Write-Host '    3  Heltec WiFi LoRa 32 V4 (with screen)'
  $pick = Read-Host '  1, 2 or 3'
  if ($pick -eq '2') { $chip = 'Heltec V3' }
  if ($pick -eq '3') { $chip = 'Heltec V4' }
}
$files = @{ 'ESP32' = 'tama-bridge-esp32.bin'; 'ESP32-C3' = 'tama-bridge-esp32c3.bin'; 'ESP32-S3' = 'tama-bridge-esp32s3.bin'; 'ESP32-C6' = 'tama-bridge-esp32c6.bin'; 'Heltec V3' = 'tama-bridge-heltec-v3.bin'; 'Heltec V4' = 'tama-bridge-heltec-v4.bin' }
$fw = Join-Path $PSScriptRoot $files[$chip]
$esptoolChip = if ($chip -like 'Heltec*') { 'esp32s3' } else { $chip.ToLower().Replace('-', '') }
Write-Host ''
Write-Host "  Found an $chip on $port. Writing $($files[$chip]) ..." -ForegroundColor Green
& $esptool --chip $esptoolChip --port $port --baud 460800 write_flash 0x0 $fw
if ($LASTEXITCODE -ne 0) {
  Write-Host '  Writing failed. Try again with BOOT held, or a slower cable/port.' -ForegroundColor Red
  Read-Host '  Press Enter to close'
  exit 1
}
Write-Host ''
Write-Host '  Done. Unplug and plug the board back in: it shows up as "Tama Bridge" in the app (Tools -> Dongle).' -ForegroundColor Green
Read-Host '  Press Enter to close'
