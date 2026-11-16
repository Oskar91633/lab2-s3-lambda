# Lab 2 - pelny przebieg na Windows (Docker Desktop). Nie wymaga instalacji AWS CLI:
# polecenia aws uruchamiane sa w kontenerze amazon/aws-cli w sieci kontenera LocalStack.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force dowody | Out-Null
Start-Transcript -Path "dowody\polecenia-wynik.txt" -Force | Out-Null

$WWW  = "oskar-raport-www"
$TPL  = "oskar-raport-szablony"
$FUNC = "oskar-raport-lambda"
$PROJ = (Get-Location).Path

function aws {
    Write-Host "PS> aws $args" -ForegroundColor Cyan
    $out = (docker run --rm --network container:localstack-main -v "${PROJ}:/aws" `
        -e AWS_ENDPOINT_URL=http://localhost:4566 -e AWS_ACCESS_KEY_ID=test `
        -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
        amazon/aws-cli @args)
    if ($LASTEXITCODE -ne 0) { throw "aws $args -> blad $LASTEXITCODE" }
    $out
}
function step($t) { Write-Host "`n===== $t =====" -ForegroundColor Yellow }

step "0. Sprawdzenie"
if (-not (Test-Path .env)) { Write-Host "Brak .env - start bez tokenu" }
docker version --format "Docker {{.Server.Version}}"

step "1. Srodowisko (docker compose)"
cmd /c "docker compose up -d --quiet-pull 2>&1"
$i = 0
do { Start-Sleep 3; $i++; $h = curl.exe -s http://localhost:4566/_localstack/health
     if ($i -gt 60) { cmd /c "docker logs --tail 40 localstack-main 2>&1";  throw "LocalStack nie wystartowal" } } until ($h -match '"lambda": "(available|running)"')
$h

step "2. S3 Website"
try { aws s3 mb "s3://$WWW" } catch { Write-Host "bucket juz istnieje" }
aws s3api put-public-access-block --bucket $WWW --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
aws s3api put-bucket-policy --bucket $WWW --policy file://s3/website-policy.json
aws s3 website "s3://$WWW" --index-document index.html
aws s3 cp www/index.html "s3://$WWW/index.html" --content-type "text/html; charset=utf-8"
aws s3 cp www/style.css  "s3://$WWW/style.css"  --content-type "text/css"
aws s3api get-bucket-website --bucket $WWW
$SITE = "http://$WWW.s3-website.localhost.localstack.cloud:4566/"
curl.exe -s $SITE | Select-String "zmiana"

step "2b. Zmiana zdania i ponowna publikacja"
$p = "www\index.html"
(Get-Content $p -Raw -Encoding UTF8).Replace("Wersja pierwsza strony opublikowana w S3.", "Zdanie zmienione po publikacji - wersja druga.") |
    Set-Content $p -Encoding UTF8 -NoNewline
aws s3 cp www/index.html "s3://$WWW/index.html" --content-type "text/html; charset=utf-8"
curl.exe -s $SITE | Select-String "zmiana"

step "3. Szablon + Lambda"
try { aws s3 mb "s3://$TPL" } catch { Write-Host "bucket juz istnieje" }
aws s3 cp lambda/template.html "s3://$TPL/template.html" --content-type "text/html; charset=utf-8"
if (Test-Path lambda\function.zip) { Remove-Item lambda\function.zip }
Compress-Archive -Path lambda\lambda_function.py -DestinationPath lambda\function.zip
try {
  aws iam create-role --role-name lambda-raport-role --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}'
} catch { Write-Host "rola juz istnieje" }
try {
  aws lambda create-function --function-name $FUNC --runtime python3.12 --handler lambda_function.lambda_handler `
    --zip-file fileb://lambda/function.zip --role arn:aws:iam::000000000000:role/lambda-raport-role `
    --environment "Variables={TEMPLATE_BUCKET=$TPL,TEMPLATE_KEY=template.html}"
} catch {
  aws lambda update-function-code --function-name $FUNC --zip-file fileb://lambda/function.zip
}
aws lambda wait function-active-v2 --function-name $FUNC
try { aws lambda create-function-url-config --function-name $FUNC --auth-type NONE } catch { }
$FURL = (docker run --rm --network container:localstack-main -e AWS_ENDPOINT_URL=http://localhost:4566 `
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli lambda get-function-url-config --function-name $FUNC --query FunctionUrl --output text).Trim()
Write-Host "Function URL: $FURL"

step "4. Testy HTTP"
(curl.exe -si "${FURL}?imie=Ola")
(curl.exe -si "${FURL}?imie=Jan")
(curl.exe -si "$FURL")
(curl.exe -si "${FURL}?imie=")
curl.exe -s  "${FURL}?imie=%3Cb%3EOla%3C/b%3E" | Select-String "<h1>"

step "5. Nowe zdanie w szablonie BEZ ponownego wdrozenia"
$t = "lambda\template.html"
(Get-Content $t -Raw -Encoding UTF8).Replace("<!-- NOWE_ZDANIE -->", '<p class="nowe">To zdanie dopisano do szablonu w S3 po wdrozeniu funkcji.</p>') |
    Set-Content $t -Encoding UTF8 -NoNewline
aws s3 cp lambda/template.html "s3://$TPL/template.html" --content-type "text/html; charset=utf-8"
curl.exe -s "${FURL}?imie=Ola" | Select-String "h1|nowe"
Write-Host "Obiekt w S3 nadal zawiera {{IMIE}}:"
aws s3 cp "s3://$TPL/template.html" - | Select-String "{{IMIE}}"
aws s3 ls
aws lambda list-functions --query "Functions[].FunctionName"

# wpisanie Function URL do raportu
$r = "dowody\02-s3-lambda.md"
(Get-Content $r -Raw -Encoding UTF8).Replace("<WKLEJ z wyniku create-function-url-config>", $FURL) | Set-Content $r -Encoding UTF8 -NoNewline

Stop-Transcript | Out-Null
Start-Process $SITE
Start-Process "${FURL}?imie=Ola"
Start-Process "${FURL}?imie=Jan"
Write-Host "`nGOTOWE. Wynik: dowody\polecenia-wynik.txt. Zrob zrzuty 3 otwartych kart do dowody\img\." -ForegroundColor Green
Read-Host "Enter aby zamknac"
