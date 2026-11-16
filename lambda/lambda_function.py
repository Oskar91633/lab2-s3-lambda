import html
import os

import boto3
from botocore.config import Config

BUCKET = os.environ.get("TEMPLATE_BUCKET", "oskar-raport-szablony")
KEY = os.environ.get("TEMPLATE_KEY", "template.html")
PLACEHOLDER = "{{IMIE}}"

# W LocalStack kontener Lambdy dostaje AWS_ENDPOINT_URL wskazujący na emulator.
_endpoint = os.environ.get("AWS_ENDPOINT_URL")
s3 = boto3.client(
    "s3",
    endpoint_url=_endpoint or None,
    config=Config(s3={"addressing_style": "path"}),
)

HTML_HEADERS = {"Content-Type": "text/html; charset=utf-8"}


def _odpowiedz(status, body):
    return {"statusCode": status, "headers": HTML_HEADERS, "body": body}


def lambda_handler(event, context):
    params = (event or {}).get("queryStringParameters") or {}
    imie = (params.get("imie") or "").strip()

    if not imie:
        return _odpowiedz(
            400,
            "<!DOCTYPE html><meta charset='utf-8'>"
            "<h1>400 – brak parametru imie</h1>"
            "<p>Dodaj do adresu parametr, np. <code>?imie=Ola</code></p>",
        )

    # Szablon pobierany przy KAŻDYM żądaniu -> zmiana w S3 widoczna bez ponownego wdrożenia
    obj = s3.get_object(Bucket=BUCKET, Key=KEY)
    szablon = obj["Body"].read().decode("utf-8")

    # html.escape: znaki specjalne (<, >, &, ") wyświetlą się jako tekst, nie jako kod
    strona = szablon.replace(PLACEHOLDER, html.escape(imie, quote=True))
    return _odpowiedz(200, strona)
