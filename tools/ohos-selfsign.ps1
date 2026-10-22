# ohos-selfsign.ps1 -- sign a HAP with a locally-generated OpenHarmony debug profile.
#
# Why this exists: installing a HAP on a HarmonyOS/Huawei device normally needs a
# Huawei-issued provisioning profile bound to the app's bundleName and to the
# device UDID.  The OpenHarmony SDK instead ships a complete offline signing
# toolchain (hap-sign-tool.jar + OpenHarmony.p12 root keys, well-known password
# 123456) which lets you mint a self-signed debug profile.  Whether a *Huawei*
# device trusts the OpenHarmony root is device-dependent -- this script is the
# experiment.
#
# Pipeline: app keypair -> app cert chain -> profile JSON -> sign-profile -> sign-app
param(
    [Parameter(Mandatory)][string]$UnsignedHap,
    [string]$BundleName = 'com.handbrake.ohos',
    [Parameter(Mandatory=$true)][string]$Udid,   # 你的设备 UDID：hdc shell bm get --udid
    [string]$WorkDir    = 'D:\handbrake-ohos\signing',
    [int]$CompatibleVersion = 12,
    [string]$DevEcoHome = 'C:\Program Files\Huawei\DevEco Studio'
)

$ErrorActionPreference = 'Continue'
$java    = "$DevEcoHome\jbr\bin\java.exe"
$keytool = "$DevEcoHome\jbr\bin\keytool.exe"
$tool    = "$WorkDir\hap-sign-tool.jar"
$ohP12   = "$WorkDir\oh.p12"
$PWD_    = '123456'

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Sign-Tool { param([string[]]$A) & $java -jar $tool @A 2>&1 | Out-String }

Write-Host "=== 1. export OpenHarmony CA certificates ===" -ForegroundColor Cyan
& $keytool -exportcert -alias "openharmony application root ca" -keystore $ohP12 -storetype PKCS12 -storepass $PWD_ -rfc -file "$WorkDir\root-ca.cer" 2>&1 | Out-Null
& $keytool -exportcert -alias "openharmony application ca"      -keystore $ohP12 -storetype PKCS12 -storepass $PWD_ -rfc -file "$WorkDir\app-ca.cer"  2>&1 | Out-Null
"root-ca.cer : $((Get-Item "$WorkDir\root-ca.cer" -ErrorAction SilentlyContinue).Length) bytes"
"app-ca.cer  : $((Get-Item "$WorkDir\app-ca.cer"  -ErrorAction SilentlyContinue).Length) bytes"

Write-Host "=== 2. generate our app keypair ===" -ForegroundColor Cyan
if (-not (Test-Path "$WorkDir\hb-app.p12")) {
    Sign-Tool @('generate-keypair','-keyAlias','hb-app-key','-keyPwd',$PWD_,'-keyAlg','ECC',
                '-keySize','NIST-P-256','-keystoreFile',"$WorkDir\hb-app.p12",'-keystorePwd',$PWD_) | Write-Host
}

Write-Host "=== 3. generate app cert chain (leaf + sub-CA + root) ===" -ForegroundColor Cyan
# NOTE: generate-app-cert mints a *new* certificate on every invocation.  The
# profile's development-certificate and the HAP's -appCertFile must therefore be
# the SAME leaf, so we generate the chain exactly once and slice the leaf out of
# it -- generating twice and using one for each makes hap-sign-tool fail with
# "verify certificate chain failed / issuer subject failed".
Sign-Tool @('generate-app-cert','-keyAlias','hb-app-key','-keyPwd',$PWD_,
            '-issuer','C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA',
            '-issuerKeyAlias','openharmony application ca','-issuerKeyPwd',$PWD_,
            '-issuerKeystoreFile',$ohP12,'-issuerKeystorePwd',$PWD_,
            '-subject','C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=HandBrakeOHOS Debug',
            '-validity','3650','-signAlg','SHA256withECDSA',
            '-keystoreFile',"$WorkDir\hb-app.p12",'-keystorePwd',$PWD_,
            '-outForm','certChain','-rootCaCertFile',"$WorkDir\root-ca.cer",'-subCaCertFile',"$WorkDir\app-ca.cer",
            '-outFile',"$WorkDir\hb-app-chain.cer") | Write-Host

# Slice the first PEM block (= the leaf) out of the chain for the profile field.
$chainText = ([IO.File]::ReadAllText("$WorkDir\hb-app-chain.cer")) -replace "`r`n","`n"
$leafPem = ([regex]::Match($chainText, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----')).Value + "`n"
[IO.File]::WriteAllText("$WorkDir\hb-app-leaf.cer", $leafPem, [Text.UTF8Encoding]::new($false))
"leaf extracted from chain: $($leafPem.Length) chars"

Write-Host "=== 4. build the debug profile JSON ===" -ForegroundColor Cyan
# Pass the PEM raw: ConvertTo-Json performs the newline escaping itself.  Doing
# it by hand double-escapes and yields "Illegal base64 character 20".
$now  = [int][double]::Parse((Get-Date -UFormat %s))
$prof = [ordered]@{
    'version-name' = '2.0.0'
    'version-code' = 2
    'uuid'         = [guid]::NewGuid().ToString()
    'validity'     = [ordered]@{ 'not-before' = $now; 'not-after' = ($now + 315360000) }
    'type'         = 'debug'
    'bundle-info'  = [ordered]@{
        'developer-id'            = 'OpenHarmony'
        'development-certificate' = $leafPem
        'bundle-name'             = $BundleName
        'apl'                     = 'normal'
        'app-feature'             = 'hos_normal_app'
    }
    'acls'         = [ordered]@{ 'allowed-acls' = @('') }
    'permissions'  = [ordered]@{ 'restricted-permissions' = @('') }
    'debug-info'   = [ordered]@{ 'device-ids' = @($Udid); 'device-id-type' = 'udid' }
    'issuer'       = 'pki_internal'
}
[IO.File]::WriteAllText("$WorkDir\hb-profile.json", ($prof | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
"wrote hb-profile.json ($((Get-Item "$WorkDir\hb-profile.json").Length) bytes)"

Write-Host "=== 5. sign the profile ===" -ForegroundColor Cyan
Sign-Tool @('sign-profile','-mode','localSign',
            '-keyAlias','openharmony application profile debug','-keyPwd',$PWD_,
            '-profileCertFile',"$WorkDir\profile-debug.pem",
            '-inFile',"$WorkDir\hb-profile.json",
            '-signAlg','SHA256withECDSA',
            '-keystoreFile',$ohP12,'-keystorePwd',$PWD_,
            '-outFile',"$WorkDir\hb-profile.p7b") | Write-Host
"hb-profile.p7b : $((Get-Item "$WorkDir\hb-profile.p7b" -ErrorAction SilentlyContinue).Length) bytes"

Write-Host "=== 6. sign the HAP ===" -ForegroundColor Cyan
$outHap = Join-Path (Split-Path $UnsignedHap) ((Split-Path $UnsignedHap -Leaf) -replace '-unsigned\.hap$','-selfsigned.hap')
Sign-Tool @('sign-app','-mode','localSign',
            '-keyAlias','hb-app-key','-keyPwd',$PWD_,
            '-appCertFile',"$WorkDir\hb-app-chain.cer",
            '-profileFile',"$WorkDir\hb-profile.p7b",
            '-inFile',$UnsignedHap,
            '-signAlg','SHA256withECDSA',
            '-keystoreFile',"$WorkDir\hb-app.p12",'-keystorePwd',$PWD_,
            '-outFile',$outHap,
            '-compatibleVersion',"$CompatibleVersion",
            '-signCode','1') | Write-Host
if (Test-Path $outHap) { Write-Host "SIGNED HAP: $outHap ($((Get-Item $outHap).Length) bytes)" -ForegroundColor Green }
else { Write-Host "SIGNING FAILED" -ForegroundColor Red }
