# install-and-smoke.ps1 -- install a signed HAP on the connected HarmonyOS device
# and smoke-test the HandBrake native engine through the app sandbox.
#
# Usage:
#   .\install-and-smoke.ps1 -Hap <path-to-signed.hap>
#   .\install-and-smoke.ps1                       # auto-detect the newest signed HAP
#
# What it checks, in order:
#   1. device reachable, and whether the HAP's bundleName is already installed
#   2. hdc install -r
#   3. launch EntryAbility via `aa start`
#   4. tail hilog for the module's own tag (HandBrakeOHOS) and for the libhb log
param(
    [string]$Hap,
    [string]$BundleName = 'com.handbrake.ohos',
    [string]$Ability    = 'EntryAbility',
    [string]$Device     = $(if ($env:OHOS_DEVICE) { $env:OHOS_DEVICE } else { '127.0.0.1:5555' }),
    [string]$DevEcoHome = 'C:\Program Files\Huawei\DevEco Studio',
    [int]$LogSeconds    = 12
)

$ErrorActionPreference = 'Continue'
$hdc = "$DevEcoHome\sdk\default\openharmony\toolchains\hdc.exe"

if (-not $Hap) {
    $cands = @(
        Get-ChildItem 'D:\handbrake-ohos\entry\build\default\outputs\default' -Filter '*signed.hap' -ErrorAction SilentlyContinue
        Get-ChildItem "$env:LOCALAPPDATA\ho-kit\sign\output" -Filter '*handbrake*' -ErrorAction SilentlyContinue
    ) | Sort-Object LastWriteTime -Descending
    if (-not $cands) { Write-Host "No signed HAP found. Pass -Hap <path>." -ForegroundColor Red; exit 1 }
    $Hap = $cands[0].FullName
}
Write-Host "HAP        : $Hap" -ForegroundColor Cyan
Write-Host "size       : $((Get-Item $Hap).Length) bytes"

Write-Host "`n=== 1. device ===" -ForegroundColor Cyan
& $hdc -t $Device shell "param get const.product.model"
$installed = (& $hdc -t $Device shell "bm dump -n $BundleName" 2>&1 | Out-String)
if ($installed -match 'bundleName') { Write-Host "already installed -> will replace (-r)" -ForegroundColor Yellow }
else { Write-Host "not installed yet" }

Write-Host "`n=== 2. install ===" -ForegroundColor Cyan
& $hdc -t $Device install -r $Hap

Write-Host "`n=== 3. launch $BundleName/$Ability ===" -ForegroundColor Cyan
& $hdc -t $Device shell "aa start -a $Ability -b $BundleName"

Write-Host "`n=== 4. hilog (${LogSeconds}s) ===" -ForegroundColor Cyan
& $hdc -t $Device shell "hilog -w clear" | Out-Null
$job = Start-Job -ScriptBlock {
    param($hdc, $Device)
    & $hdc -t $Device shell "hilog" 2>&1
} -ArgumentList $hdc, $Device
Start-Sleep -Seconds $LogSeconds
Stop-Job $job -ErrorAction SilentlyContinue
Receive-Job $job -ErrorAction SilentlyContinue |
    Select-String -Pattern 'HandBrakeOHOS|HandBrake|libhb|hb_|x264|ffmpeg|Scanning|Encoding' |
    ForEach-Object { $_.Line } | Select-Object -First 60
Remove-Job $job -Force -ErrorAction SilentlyContinue

Write-Host "`nIf the engine loaded, you should see the libhb banner and a HandBrakeCLI"
Write-Host "run. To run a real transcode, push a sample clip and call runCli() from"
Write-Host "the app with e.g. ['-i','<in>','-o','<out>','-e','x264','-q','22']."
