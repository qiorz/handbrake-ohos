# OHOS / DevEco environment for cross-compiling to HarmonyOS arm64
# NOTE: keep ErrorActionPreference at 'Continue' -- many OHOS tools (java signer,
# hdc, clang) write progress/warnings to stderr, which would otherwise abort.
$ErrorActionPreference = 'Continue'

$env:DEVECO_HOME   = "C:\Program Files\Huawei\DevEco Studio"
$env:OHOS_SDK      = "$env:DEVECO_HOME\sdk\default\openharmony"
$env:OHOS_HMS_SDK  = "$env:DEVECO_HOME\sdk\default\hms"
$env:OHOS_NATIVE   = "$env:OHOS_SDK\native"
$env:OHOS_SYSROOT  = "$env:OHOS_NATIVE\sysroot"
$env:OHOS_LLVM_BIN = "$env:OHOS_NATIVE\llvm\bin"
$env:OHOS_CMAKE_BIN= "$env:OHOS_NATIVE\build-tools\cmake\bin"
$env:OHOS_TOOLCHAIN_CMAKE = "$env:OHOS_NATIVE\build\cmake\ohos.toolchain.cmake"
$env:JAVA_HOME     = "$env:DEVECO_HOME\jbr"
$env:OHOS_JAVA     = "$env:DEVECO_HOME\jbr\bin\java.exe"
$env:OHOS_HDC      = "$env:OHOS_SDK\toolchains\hdc.exe"
$env:OHOS_SIGN_TOOL= "$env:OHOS_SDK\toolchains\lib\binary-sign-tool.jar"
$env:OHOS_NODE     = "$env:DEVECO_HOME\tools\node\node.exe"
$env:OHOS_OHPM     = "$env:DEVECO_HOME\tools\ohpm\bin\ohpm.bat"
$env:OHOS_HVIGOR   = "$env:DEVECO_HOME\tools\hvigor\bin\hvigorw.bat"

$env:OHOS_DEVICE   = "127.0.0.1:5555"   # 改成你的设备地址（hdc list targets -v）

# Target triple used by the NDK clang driver
$env:OHOS_TARGET   = "aarch64-linux-ohos"

$env:PATH = "$env:OHOS_LLVM_BIN;$env:OHOS_CMAKE_BIN;$env:JAVA_HOME\bin;$env:PATH"

function Get-OhosCC { "$env:OHOS_LLVM_BIN\clang.exe" }
function Get-OhosCXX { "$env:OHOS_LLVM_BIN\clang++.exe" }

# Sign an OHOS native executable in place (required before it will execute on device)
function Invoke-OhosSign {
    param([Parameter(Mandatory)][string]$Path)
    & $env:OHOS_JAVA -jar $env:OHOS_SIGN_TOOL sign -inFile $Path -outFile $Path -selfSign "1"
}

function Invoke-Hdc {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    & $env:OHOS_HDC -t $env:OHOS_DEVICE @Args
}
