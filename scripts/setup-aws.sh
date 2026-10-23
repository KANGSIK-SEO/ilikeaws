#!/bin/bash
# AWS 웹 서비스 인프라 자동 프로비저닝 스크립트 (서울 리전 ap-northeast-2)
# 구성 요소: VPC(10.0.0.0/16) -> Subnet(10.0.1.0/24) -> IGW -> Route(0.0.0.0/0 -> IGW)
#           -> Security Group(HTTP 80 전체, SSH 22 내 IP만) -> Elastic IP -> EC2(t2.micro / Ubuntu 22.04 LTS)
set -euo pipefail

REGION="ap-northeast-2"
AZ="ap-northeast-2a"
VPC_NAME="mission-vpc"
SUBNET_NAME="mission-public-subnet"
IGW_NAME="mission-igw"
RTB_NAME="mission-rtb"
SG_NAME="mission-web-sg"
KEY_NAME="mission-key"
INSTANCE_NAME="mission-web-server"
INSTANCE_TYPE="t2.micro"

# 현재 접속 환경의 공인 IP 자동 감지 (/32)
MY_IP="$(curl -s https://api.ipify.org)/32"

echo "=== [Ilikeaws] AWS 클라우드 인프라 자동 구성을 시작합니다 ==="
echo "리전        : $REGION ($AZ)"
echo "내 공인 IP  : $MY_IP (SSH 22번 포트 단독 허용)"

# 1. VPC 생성 (10.0.0.0/16)
echo "1) VPC 생성 중..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" --region "$REGION"
echo "   VPC ID: $VPC_ID"

# 2. Public Subnet 생성 (10.0.1.0/24)
echo "2) Public Subnet 생성 중..."
SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone "$AZ" --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME}]" \
  --query 'Subnet.SubnetId' --output text)
echo "   Subnet ID: $SUBNET_ID"

# 3. Internet Gateway 생성 및 VPC 연결
echo "3) Internet Gateway 생성 및 연결 중..."
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "   IGW ID: $IGW_ID"

# 4. Route Table 생성 및 0.0.0.0/0 -> IGW 경로 등록, 서브넷 연결
echo "4) Route Table 설정 중..."
RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$RTB_NAME}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID" --region "$REGION"
echo "   Route Table ID: $RTB_ID (0.0.0.0/0 -> $IGW_ID)"

# 5. Security Group 생성 및 최소 인바운드 규칙 등록
echo "5) Security Group 생성 및 인바운드 규칙 설정 중..."
SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Security group for web server" \
  --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)

# HTTP 80 포트: 0.0.0.0/0 전체 허용
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"

# SSH 22 포트: 내 공인 IP만 허용
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP" --region "$REGION"
echo "   Security Group ID: $SG_ID (Port 80: 0.0.0.0/0, Port 22: $MY_IP)"

# 6. 키페어 생성 (기존 키페어 없을 시)
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "6) SSH 키페어($KEY_NAME) 생성 중..."
  mkdir -p ~/.ssh
  aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --query 'KeyMaterial' --output text > ~/.ssh/"$KEY_NAME".pem
  chmod 400 ~/.ssh/"$KEY_NAME".pem
  echo "   키페어 저장 위치: ~/.ssh/${KEY_NAME}.pem"
fi

# 7. 최신 Ubuntu 22.04 LTS AMI ID 조회
echo "7) Ubuntu 22.04 LTS AMI 조회 중..."
AMI_ID=$(aws ec2 describe-images --owners 099720109477 --region "$REGION" \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
echo "   AMI ID: $AMI_ID"

# 8. EC2 User Data 작성 (Nginx 설치, 웹 페이지 및 /health 설정)
USER_DATA=$(cat <<'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y nginx curl

# 정적 웹페이지 및 /health 고정 응답 생성
mkdir -p /var/www/html
echo "OK" > /var/www/html/health

cat > /etc/nginx/sites-available/default <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    location = /health {
        default_type text/plain;
        return 200 "OK\n";
    }
}
NGINX

# 서비스 기동 및 활성화
systemctl enable nginx
systemctl restart nginx
EOF
)

# 9. EC2 인스턴스 시작 (8GiB gp3, t2.micro)
echo "8) EC2 인스턴스($INSTANCE_NAME) 실행 중..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' --output text)
echo "   Instance ID: $INSTANCE_ID (실행 대기 중...)"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# 10. Elastic IP 할당 및 인스턴스 연결
echo "9) Elastic IP 할당 및 바인딩 중..."
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=mission-eip}]" \
  --query 'AllocationId' --output text)
PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --region "$REGION" --query 'Addresses[0].PublicIp' --output text)

aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" --region "$REGION"
echo "   Elastic IP 바인딩 완료: $PUBLIC_IP"

echo ""
echo "=========================================================="
echo "🎉 AWS 웹 인프라 배포가 성공적으로 완료되었습니다!"
echo " (A) 웹 브라우저 접속 : http://${PUBLIC_IP}"
echo " (B) 헬스체크 호출    : curl -i http://${PUBLIC_IP}/health"
echo " SSH 원격 접속        : ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo "=========================================================="
