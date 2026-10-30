# ==============================================================================
# 🐳 Dockerfile: 웹 서버 컨테이너 빌드 명세서
# ==============================================================================
# 베이스 이미지: 경량화된 Linux 배포판인 Alpine 기반의 최신 Nginx 웹 서버 사용
# Alpine은 용량이 매우 작아서(수 MB 단위) 다운로드/배포 속도가 빠르고 보안에 유리합니다.
FROM nginx:alpine

# 1. 로컬의 웹 정적 리소스(HTML) 및 헬스체크 파일을 컨테이너 내부 웹 루트 디렉토리로 복사
#    - index.html: 방문자에게 보여줄 메인 웹 페이지
#    - health: 로드밸런서나 모니터링 시스템이 서버 생존 여부를 확인할 때 응답하는 파일 ("OK")
COPY web/index.html /usr/share/nginx/html/index.html
COPY web/health /usr/share/nginx/html/health

# 2. 커스텀 Nginx 설정 파일 복사
#    컨테이너 내 기본 설정을 덮어씌워 80번 포트 및 라우팅(/, /health) 규칙을 적용합니다.
COPY web/nginx.conf /etc/nginx/conf.d/default.conf

# 3. 컨테이너가 외부와 통신할 네트워크 포트 명시 (HTTP 기본 포트: 80)
EXPOSE 80

# 4. 컨테이너 시작 시 Nginx를 포그라운드(daemon off;)로 실행
#    포그라운드로 실행해야 Docker 컨테이너 프로세스가 종료되지 않고 계속 살아있게 됩니다.
CMD ["nginx", "-g", "daemon off;"]

