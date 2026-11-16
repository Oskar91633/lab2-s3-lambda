#!/usr/bin/env bash
# Lab 2 – wszystkie polecenia w kolejności. Uruchamiaj z katalogu głównego repo.
# Wynik zapisuj: bash dowody/polecenia.sh 2>&1 | tee dowody/polecenia-wynik.txt
set -euo pipefail

# ---------- 0. AWS CLI -> LocalStack ----------
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

WWW_BUCKET=oskar-raport-www
TPL_BUCKET=oskar-raport-szablony
FUNC=oskar-raport-lambda

# ---------- 1. Środowisko ----------
# cp .env.example .env   # i wpisz token
docker compose up -d
until curl -s http://localhost:4566/_localstack/health | grep -q '"lambda": "\(available\|running\)"'; do sleep 2; done
curl -s http://localhost:4566/_localstack/health

# ---------- 2. S3 Website ----------
aws s3 mb s3://$WWW_BUCKET
aws s3api put-public-access-block --bucket $WWW_BUCKET \
  --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-policy --bucket $WWW_BUCKET --policy file://s3/website-policy.json
aws s3 website s3://$WWW_BUCKET --index-document index.html
aws s3 cp www/index.html s3://$WWW_BUCKET/index.html --content-type "text/html; charset=utf-8"
aws s3 cp www/style.css  s3://$WWW_BUCKET/style.css  --content-type "text/css"
aws s3api get-bucket-website --bucket $WWW_BUCKET
echo "S3 Website: http://$WWW_BUCKET.s3-website.localhost.localstack.cloud:4566/"
curl -s "http://$WWW_BUCKET.s3-website.localhost.localstack.cloud:4566/"
# -> ZRZUT 1a (przed zmianą, opcjonalnie)

# zmiana jednego zdania i ponowna publikacja
sed -i 's|Wersja pierwsza strony opublikowana w S3.|Zdanie zmienione po publikacji – wersja druga.|' www/index.html
aws s3 cp www/index.html s3://$WWW_BUCKET/index.html --content-type "text/html; charset=utf-8"
curl -s "http://$WWW_BUCKET.s3-website.localhost.localstack.cloud:4566/" | grep zmiana
# -> ZRZUT 1 (pasek adresu + styl CSS + zmienione zdanie)

# ---------- 3. Lambda + szablon ----------
aws s3 mb s3://$TPL_BUCKET            # domyślne (prywatne) ustawienia dostępu
aws s3 cp lambda/template.html s3://$TPL_BUCKET/template.html --content-type "text/html; charset=utf-8"

# paczka zawiera TYLKO kod funkcji (szablon zostaje w S3)
(cd lambda && rm -f function.zip && zip function.zip lambda_function.py)

aws iam create-role --role-name lambda-raport-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws lambda create-function --function-name $FUNC \
  --runtime python3.12 --handler lambda_function.lambda_handler \
  --zip-file fileb://lambda/function.zip \
  --role arn:aws:iam::000000000000:role/lambda-raport-role \
  --environment "Variables={TEMPLATE_BUCKET=$TPL_BUCKET,TEMPLATE_KEY=template.html}"
aws lambda wait function-active-v2 --function-name $FUNC

FURL=$(aws lambda create-function-url-config --function-name $FUNC --auth-type NONE \
  --query FunctionUrl --output text)
echo "Function URL: $FURL"

# ---------- 4. Testy ----------
curl -si "${FURL}?imie=Ola" | head -20          # 200 + Content-Type
curl -si "${FURL}?imie=Jan" | head -20
curl -si "${FURL}"                               # 400 bez parametru
curl -si "${FURL}?imie="                         # 400 pusta wartość
curl -s  "${FURL}?imie=%3Cb%3EOla%3C/b%3E" | grep '<h1>'   # znaki specjalne jako tekst
# -> ZRZUT 2 (Ola) i ZRZUT 3 (Jan) w przeglądarce

# ---------- 5. Zmiana szablonu BEZ ponownego wdrożenia ----------
sed -i 's|<!-- NOWE_ZDANIE -->|<p class="nowe">To zdanie dopisano do szablonu w S3 po wdrożeniu funkcji.</p>|' lambda/template.html
aws s3 cp lambda/template.html s3://$TPL_BUCKET/template.html --content-type "text/html; charset=utf-8"
curl -s "${FURL}?imie=Ola" | grep -E 'h1|nowe'
# -> odśwież stronę w przeglądarce, ZRZUT z nowym zdaniem

# odczyt obiektu z S3 – nadal zawiera {{IMIE}}
aws s3 cp s3://$TPL_BUCKET/template.html - | grep -n '{{IMIE}}'

# lista zasobów do raportu
aws s3 ls
aws lambda list-functions --query 'Functions[].FunctionName'
aws lambda get-function-url-config --function-name $FUNC
