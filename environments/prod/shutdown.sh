#!/bin/bash
# GCE가 VM을 중지·교체할 때 앱에 SIGTERM을 보내고 최대 60초 기다립니다.
# 앱도 SIGTERM을 처리해야 진행 중인 요청을 정상적으로 마칠 수 있습니다.
set -euo pipefail

if command -v docker >/dev/null 2>&1 && docker container inspect app >/dev/null 2>&1; then
  docker stop --time 60 app
fi
