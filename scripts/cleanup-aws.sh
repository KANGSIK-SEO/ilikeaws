#!/bin/bash
# ==============================================================================
# 🧹 cleanup-aws.sh: AWS 실습 리소스 완전 정리 및 과금 방지 스크립트
# ==============================================================================
# ⚠️ 왜 "역순(Reverse Order)"으로 지워야 할까요?
# AWS는 상위 리소스(VPC, 서브넷 등)가 하위 리소스(EC2, 보안그룹)에 연결되어 있으면
# '의존성 오류(DependencyViolation)'가 발생하여 삭제되지 않습니다.
# 따라서 생성한 순서의 정반대로 꼼꼼히 지워야 과금 요소를 100% 깔끔하게 제거할 수 있습니다:
#
# 삭제 순서:
# 1. EC2 인스턴스 종료 (인스턴스가 물고 있는 EBS 루트 볼륨 자동 삭제)
# 2. 탄력적 IP (Elastic IP) 반환 (인스턴스에 안 붙어있는 유휴 IP는 시간당 과금됨)
# 3. 보안 그룹 (Security Group) 삭제
# 4. 서브넷 (Public Subnet) 삭제
# 5. 인터넷 게이트웨이(IGW) 연결 분리(Detach) 후 삭제
# 6. 커스텀 라우팅 테이블 (Route Table) 삭제
# 7. 최상위 가상 네트워크 (VPC) 삭제
# 8. 최종 잔여 리소스 0건 검증 (안심 과금 차단)
# ==============================================================================
set -euo pipefail

REGION="ap-northeast-2"
INSTANCE_NAME="mission-web-server"
SG_NAME="mission-web-sg"
SUBNET_NAME="mission-public-subnet"
RTB_NAME="mission-rtb"
IGW_NAME="mission-igw"
VPC_NAME="mission-vpc"
EIP_TAG="mission-eip"

echo "=== [Ilikeaws] AWS 실습 리소스 완전 정리를 시작합니다 ==="

# 1. EC2 인스턴스 종료
echo "1) EC2 인스턴스 종료 중..."
INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped,pending" \
  --query "Reservations[*].Instances[*].InstanceId" --output text)

if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
  echo "   종료 대상 인스턴스: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION"
  echo "   인스턴스 완전 종료(Terminated) 대기 중..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
  echo "   ✔ EC2 인스턴스 및 EBS 부팅 볼륨 종료 완료"
else
  echo "   ✔ 실행/중지 중인 EC2 인스턴스 없음"
fi

# 2. Elastic IP 릴리스
echo "2) Elastic IP 릴리스(해제) 중..."
ALLOC_IDS=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:Name,Values=$EIP_TAG" \
  --query "Addresses[*].AllocationId" --output text)

if [ -n "$ALLOC_IDS" ] && [ "$ALLOC_IDS" != "None" ]; then
  for ALLOC_ID in $ALLOC_IDS; do
    echo "   릴리스 대상 EIP: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID" --region "$REGION" || true
  done
  echo "   ✔ Elastic IP 릴리스 완료 (유휴 과금 방지)"
else
  echo "   ✔ 할당된 Elastic IP 없음"
fi

# 3. Security Group 삭제
echo "3) Security Group 삭제 중..."
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query "SecurityGroups[*].GroupId" --output text)

if [ -n "$SG_IDS" ] && [ "$SG_IDS" != "None" ]; then
  for SG_ID in $SG_IDS; do
    echo "   삭제 대상 SG: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" || true
  done
  echo "   ✔ Security Group 삭제 완료"
else
  echo "   ✔ 삭제 대상 Security Group 없음"
fi

# 4. 서브넷 및 라우팅 테이블 삭제
echo "4) Subnet 및 Route Table 삭제 중..."
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:Name,Values=$SUBNET_NAME" \
  --query "Subnets[*].SubnetId" --output text)

if [ -n "$SUBNET_IDS" ] && [ "$SUBNET_IDS" != "None" ]; then
  for SUB_ID in $SUBNET_IDS; do
    echo "   삭제 대상 Subnet: $SUB_ID"
    aws ec2 delete-subnet --subnet-id "$SUB_ID" --region "$REGION" || true
  done
  echo "   ✔ Subnet 삭제 완료"
fi

RTB_IDS=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=$RTB_NAME" \
  --query "RouteTables[*].RouteTableId" --output text)

if [ -n "$RTB_IDS" ] && [ "$RTB_IDS" != "None" ]; then
  for RTB_ID in $RTB_IDS; do
    echo "   삭제 대상 Route Table: $RTB_ID"
    aws ec2 delete-route-table --route-table-id "$RTB_ID" --region "$REGION" || true
  done
  echo "   ✔ Route Table 삭제 완료"
fi

# 5. Internet Gateway 디태치 및 삭제
echo "5) Internet Gateway 분리 및 삭제 중..."
VPC_IDS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query "Vpcs[*].VpcId" --output text)

IGW_IDS=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=tag:Name,Values=$IGW_NAME" \
  --query "InternetGateways[*].InternetGatewayId" --output text)

if [ -n "$IGW_IDS" ] && [ "$IGW_IDS" != "None" ]; then
  for IGW_ID in $IGW_IDS; do
    if [ -n "$VPC_IDS" ] && [ "$VPC_IDS" != "None" ]; then
      for VPC_ID in $VPC_IDS; do
        echo "   VPC($VPC_ID)에서 IGW($IGW_ID) 분리 중..."
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" || true
      done
    fi
    echo "   IGW($IGW_ID) 완전 삭제 중..."
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" || true
  done
  echo "   ✔ Internet Gateway 삭제 완료"
fi

# 6. VPC 삭제
echo "6) VPC 삭제 중..."
if [ -n "$VPC_IDS" ] && [ "$VPC_IDS" != "None" ]; then
  for VPC_ID in $VPC_IDS; do
    echo "   VPC($VPC_ID) 삭제 중..."
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
  done
  echo "   ✔ VPC 삭제 완료"
fi

echo ""
echo "=== 잔여 과금 리소스 검증 (모두 빈 줄이어야 정상) ==="
echo -n "1. 인스턴스 잔여: "
aws ec2 describe-instances --region "$REGION" --filters "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].InstanceId" --output text
echo -n "2. 미사용 볼륨 잔여: "
aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=available" --query "Volumes[*].VolumeId" --output text
echo -n "3. Elastic IP 잔여: "
aws ec2 describe-addresses --region "$REGION" --query "Addresses[*].PublicIp" --output text
echo -n "4. 커스텀 VPC 잔여: "
aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[*].VpcId" --output text

echo "🎉 모든 실습 리소스 정리가 완료되었습니다. 과금이 발생하지 않습니다!"
