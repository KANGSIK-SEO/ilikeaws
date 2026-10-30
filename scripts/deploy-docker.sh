#!/bin/bash
# ==============================================================================
# 🚀 deploy-docker.sh: EC2 가상머신 내부 Docker 컨테이너 배포 및 검증 스크립트
# ==============================================================================
# 역할:
# 1) 우분투(Ubuntu)에 도커 엔진이 없으면 자동으로 설치합니다.
# 2) 호스트에 기존에 돌고 있던 Nginx 서비스를 끕니다 (포트 80 충돌 방지).
# 3) Dockerfile을 읽어 웹 이미지(ilikeaws-web:latest)를 빌드합니다.
# 4) 컨테이너를 백그라운드(-d)로 실행하고 80번 포트를 연결합니다.
# 5) curl 명령어로 웹서버 및 /health 경로가 잘 작동하는지 셀프 점검합니다.
# ==============================================================================
set -euo pipefail

echo "=== [Ilikeaws] Docker 컨테이너 웹 서비스 배포 (Bonus 2) ==="

# 1. Docker 설치 확인 및 미설치 시 설치
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker가 설치되어 있지 않습니다. Docker 엔진 설치를 진행합니다..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER" || true
fi

# 2. 호스트 Nginx 중지 (80 포트 바인딩 충돌 방지)
#    서버 자체의 Nginx와 도커 컨테이너의 Nginx가 같은 80번 포트를 쓰려 하면 충돌하므로 호스트 것을 끕니다.
if systemctl is-active --quiet nginx 2>/dev/null; then
  echo "호스트 Nginx 서비스를 중지합니다 (Docker 80:80 바인딩용)..."
  sudo systemctl stop nginx
  sudo systemctl disable nginx
fi

# 3. Docker 이미지 빌드 (Dockerfile 지시어 기반)
echo "ilikeaws-web:latest 컨테이너 이미지 빌드 중..."
sudo docker build -t ilikeaws-web:latest .

# 4. 기존 컨테이너 정리 후 새 컨테이너 백그라운드 실행
#    -d: 백그라운드 실행 (터미널 점유 방지)
#    -p 80:80: 외부 접속 80 포트를 컨테이너 내부 80 포트로 연결
#    --restart always: 서버가 재부팅되어도 자동으로 컨테이너 부활
sudo docker rm -f ilikeaws-web-server 2>/dev/null || true
echo "컨테이너 실행 (포트 포워딩 80:80)..."
sudo docker run -d \
  --name ilikeaws-web-server \
  --restart always \
  -p 80:80 \
  ilikeaws-web:latest

# 5. 상태 확인 및 서비스 검증
echo ""
echo "=== 1) Docker 컨테이너 상태 (docker ps) ==="
sudo docker ps --filter "name=ilikeaws-web-server"

echo ""
echo "=== 2) 내부 웹 페이지 응답 검증 (curl http://localhost) ==="
curl -sI http://localhost | head -n 5

echo ""
echo "=== 3) 내부 /health 헬스체크 검증 (curl http://localhost/health) ==="
curl -i http://localhost/health

