#!/bin/bash
# EC2 인스턴스 내부에서 Docker 컨테이너로 웹 서비스 배포 및 검증 (보너스 과제 2)
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
if systemctl is-active --quiet nginx 2>/dev/null; then
  echo "호스트 Nginx 서비스를 중지합니다 (Docker 80:80 바인딩용)..."
  sudo systemctl stop nginx
  sudo systemctl disable nginx
fi

# 3. Docker 이미지 빌드
echo "ilikeaws-web:latest 컨테이너 이미지 빌드 중..."
sudo docker build -t ilikeaws-web:latest .

# 4. 기존 컨테이너 정리 후 실행
sudo docker rm -f ilikeaws-web-server 2>/dev/null || true
echo "컨테이너 실행 (포트 포워딩 80:80)..."
sudo docker run -d \
  --name ilikeaws-web-server \
  --restart always \
  -p 80:80 \
  ilikeaws-web:latest

# 5. 상태 확인
echo ""
echo "=== Docker 컨테이너 상태 (docker ps) ==="
sudo docker ps --filter "name=ilikeaws-web-server"

echo ""
echo "=== 내부 헬스체크 검증 (curl http://localhost) ==="
curl -sI http://localhost | head -n 5

echo ""
echo "=== 내부 /health 헬스체크 검증 (curl http://localhost/health) ==="
curl -i http://localhost/health
