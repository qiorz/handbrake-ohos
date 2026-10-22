# hokit-openfile.ps1 -- fill in HoKit's native "选择应用包" file dialog via UI Automation.
#
# The drop zone in HoKit's 一键签装 page opens a standard Win32 common dialog
# (class #32770).  Native dialogs expose a proper UIA tree (unlike Chromium's
# renderer), so we can set the File name field and press 打开 deterministically
# instead of blind-typing.
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$DialogTitle = '选择应用包'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

# 等对话框出现
$dlg = $null
for ($i = 0; $i -lt 20; $i++) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $DialogTitle)
    $dlg = $AE::RootElement.FindFirst($TS::Children, $cond)
    if ($dlg) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $dlg) { Write-Host "没找到对话框 '$DialogTitle'"; exit 1 }
Write-Host "对话框: '$($dlg.Current.Name)' class=$($dlg.Current.ClassName)" -ForegroundColor Green

# 找“文件名”编辑框：优先用 AutomationId 1001（common dialog 的固定 id）
$edit = $null
foreach ($id in @('1001', '1148')) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    $edit = $dlg.FindFirst($TS::Descendants, $c)
    if ($edit) { break }
}
if (-not $edit) {
    # 退路：第一个 Edit
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit)
    $edit = $dlg.FindFirst($TS::Descendants, $c)
}
if (-not $edit) { Write-Host "没找到文件名输入框"; exit 1 }
Write-Host "文件名框: id=$($edit.Current.AutomationId) name='$($edit.Current.Name)'"

$vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$vp.SetValue($Path)
Start-Sleep -Milliseconds 400
Write-Host "已填入: $($vp.Current.Value)"

# 点“打开(O)”
$bc = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, '1')
$open = $dlg.FindFirst($TS::Descendants, $bc)
if (-not $open) {
    $bc2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty,
             [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $dlg.FindAll($TS::Descendants, $bc2)) {
        if ($b.Current.Name -match '打开|Open') { $open = $b; break }
    }
}
if (-not $open) { Write-Host "没找到打开按钮"; exit 1 }
Write-Host "打开按钮: '$($open.Current.Name)'"
$ip = $open.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$ip.Invoke()
Write-Host "已点击打开 ✅" -ForegroundColor Green
