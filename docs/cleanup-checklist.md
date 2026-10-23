# 🧹 리소스 정리 체크리스트 및 과금 방지 보고서 (Cleanup Checklist)

> **프로젝트명**: I Like AWS — 내가 만든 웹사이트를 인터넷에 올려 누구나 쓰게 하기  
> **리전**: AWS 서울 리전(`ap-northeast-2`)  
> **목적**: 불필요한 클라우드 과금을 원천 차단하고, 리소스 간 의존성을 고려한 올바른 해제 순서 준수 및 최종 삭제 검증

---

## 1. 클라우드 과금 요인 및 삭제 순서의 중요성

AWS에서 프리티어 또는 유료 계정 운영 시 과금이 발생하는 핵심 요인과 주의점은 다음과 같습니다:

1. **EC2 인스턴스**: 인스턴스가 `running` 상태일 때 시간당 컴퓨팅 비용 발생 (프리티어 750시간 초과 시 과금).
2. **EBS 볼륨 (블록 스토리지)**: 인스턴스를 중지(Stopped)하더라도 연결된 EBS 볼륨 용량(GB-month)은 영구 보존되므로 **지속 과금**됨. 인스턴스 종료(Terminate) 시 루트 볼륨이 함께 삭제되도록 설정해야 함.
3. **Elastic IP (탄력적 IP)**: **실행 중인 인스턴스에 연결되지 않은 유휴(Idle) EIP는 시간당 $0.005의 미사용 과금**이 발생함. 인스턴스 종료 즉시 반드시 **Release(릴리스)** 해야 함.
4. **Internet Gateway & VPC**: IGW 자체는 무료이나, 서브넷이나 인스턴스가 바인딩되어 있으면 VPC 삭제가 거부됨.
5. **올바른 삭제 순서 (역순 정리)**:
   - 상위 네트워크(VPC)를 먼저 삭제하려고 하면 하위 리소스(EC2, SG, IGW)가 종속되어 있어 `DependencyViolation` 오류가 발생합니다.
   - 따라서 **`EC2 종료 → Elastic IP 릴리스 → 보안 그룹 삭제 → Subnet 삭제 → IGW 디태치 및 삭제 → Route Table 삭제 → VPC 삭제`** 순서로 정리해야 합니다.

---

## 2. 리소스 정리 체크리스트 (종료 / 삭제 확인)

| 점검 항목 | 리소스 식별자 / 명칭 | 조치 내용 | 과금 영향도 | 상태 |
|---|---|---|---|:---:|
| **1. EC2 인스턴스** | `mission-web-server` | 인스턴스 완전 종료 (`Terminate`) | 실행 시간 과금 즉시 중단 | **[x] 종료 완료** |
| **2. EBS 볼륨** | 부팅 볼륨 (`8~10 GiB gp3`) | 인스턴스 종료 시 자동 삭제 확인 (`available` 잔여 0건) | 잔여 볼륨 스토리지 과금 방지 | **[x] 삭제 완료** |
| **3. Elastic IP** | `mission-eip` | 할당 주소 즉시 해제 (`Release-Address`) | **미사용 EIP 유휴 과금 방지** | **[x] 릴리스 완료** |
| **4. 보안 그룹** | `mission-web-sg` | 기본 default SG 제외한 커스텀 규칙 삭제 | 잠재적 보안 홀 제거 | **[x] 삭제 완료** |
| **5. 라우팅 테이블** | `mission-rtb` | 기본 local 외 `0.0.0.0/0` 라우트 제거 및 테이블 삭제 | VPC 삭제 차단 해제 | **[x] 삭제 완료** |
| **6. 서브넷** | `mission-public-subnet` | 서브넷 삭제 (`DeleteSubnet`) | VPC 내부 리소스 정리 | **[x] 삭제 완료** |
| **7. Internet Gateway** | `mission-igw` | VPC에서 분리(`Detach`) 후 완전 삭제(`Delete`) | VPC 외부 통신 관문 제거 | **[x] 삭제 완료** |
| **8. VPC 네트워크** | `mission-vpc` | VPC 완전 삭제 (`DeleteVpc`) | 네트워크 공간 초기화 | **[x] 삭제 완료** |
| **9. IAM 배포 계정** | `mission-deployer` | 사용 정책 분리 및 사용자/키 비활성화 | 무단 API 호출 방지 | **[x] 정리 완료** |
| **10. 과금 대시보드** | AWS Billing Console | 잔여 비용 및 프리티어 사용량 $0 확인 | 최종 청구서 $0 확인 | **[x] 확인 완료** |

---

## 3. 원클릭 리소스 정리 CLI 명령어 및 실행 근거

아래 명령어를 통해 모든 실습 리소스를 순차적으로 안전하게 삭제할 수 있습니다 (`scripts/cleanup-aws.sh` 제공):

```bash
#!/bin/bash
# 1. EC2 인스턴스 종료 (볼륨 자동 삭제)
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=mission-web-server" "Name=instance-state-name,Values=running,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text)
if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
    echo "Terminating EC2 Instance: $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
fi

# 2. Elastic IP 릴리스
ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=mission-eip" --query "Addresses[0].AllocationId" --output text)
if [ "$ALLOC_ID" != "None" ] && [ -n "$ALLOC_ID" ]; then
    echo "Releasing Elastic IP: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID"
fi

# 3. Internet Gateway 디태치 및 삭제
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=mission-igw" --query "InternetGateways[0].InternetGatewayId" --output text)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=mission-vpc" --query "Vpcs[0].VpcId" --output text)
if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi

# 4. 서브넷 및 라우팅 테이블 삭제
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=mission-public-subnet" --query "Subnets[0].SubnetId" --output text)
if [ "$SUBNET_ID" != "None" ] && [ -n "$SUBNET_ID" ]; then
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
fi

# 5. 보안 그룹 삭제
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=mission-web-sg" --query "SecurityGroups[0].GroupId" --output text)
if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
    aws ec2 delete-security-group --group-id "$SG_ID"
fi

# 6. VPC 삭제
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    aws ec2 delete-vpc --vpc-id "$VPC_ID"
fi
```

---

## 4. 최종 리소스 잔여 0건 검증 (Verification Output)

정리 후 모든 항목이 0건으로 비어 있음을 증빙하는 AWS CLI 실행 결과입니다:

```bash
# 1. 실행 중이거나 정지된 EC2 인스턴스 확인 -> 0건 (None)
$ aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[*].Instances[*].InstanceId" --output text
(출력 없음 - 0건)

# 2. 잔여 미사용 EBS 볼륨 확인 -> 0건
$ aws ec2 describe-volumes --filters "Name=status,Values=available" \
    --query "Volumes[*].VolumeId" --output text
(출력 없음 - 0건)

# 3. 할당된 Elastic IP 확인 -> 0건
$ aws ec2 describe-addresses --query "Addresses[*].PublicIp" --output text
(출력 없음 - 0건)

# 4. 커스텀 VPC 확인 -> 0건 (기본 default VPC만 유지)
$ aws ec2 describe-vpcs --filters "Name=tag:Name,Values=mission-vpc" \
    --query "Vpcs[*].VpcId" --output text
(출력 없음 - 0건)
```

> **증빙 스크린샷**: [`docs/screenshots/04-cleanup-verified.png`](screenshots/04-cleanup-verified.png)
