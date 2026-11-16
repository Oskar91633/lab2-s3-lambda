@echo off
cd /d "%~dp0"
(docker version & docker compose version & docker ps -a & where aws) > dowody\docker-check.txt 2>&1
