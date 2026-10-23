FROM nginx:alpine

# 정적 웹 파일 및 헬스체크 파일 복사
COPY web/index.html /usr/share/nginx/html/index.html
COPY web/health /usr/share/nginx/html/health

# Nginx 커스텀 설정 복사
COPY web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
