# 🛠️ 트러블슈팅 보고서 (Troubleshooting Report)

> **프로젝트명**: I Like AWS — 내가 만든 웹사이트를 인터넷에 올려 누구나 쓰게 하기  
> **환경**: AWS 서울 리전(`ap-northeast-2`) · VPC 격리 네트워크 · EC2 `t2.micro` (Ubuntu 22.04 LTS) · Nginx 1.x

클라우드 네트워크 설계, 보안 그룹 접근 제어, IAM 최소권한 적용 및 웹 애플리케이션 배포 과정에서 발생한 실제 통신 및 권한 문제 4건을 `증상 → 가설 → 검증 → 조치 → 결과 → 재발방지` 절차로 분석하고 해결한 기록입니다.

---

## 📌 목차
1. [사례 1 — 보안 그룹 SSH 소스 IP(/32) 불일치로 인한 SSH 접속 타임아웃](#case-1)
2. [사례 2 — 서브넷 라우팅 테이블(0.0.0.0/0 → IGW) 누락으로 인한 외부 접속 차단](#case-2)
3. [사례 3 — Nginx 프로세스 중복 및 /health 경로 404 오류 해결](#case-3)
4. [사례 4 — IAM 최소권한 정책 적용 중 ec2:RunInstances 세부 액션 누락 및 보안 격리 검증](#case-4)

---

<a id="case-1"></a>
## 사례 1 — 보안 그룹 SSH 소스 IP(/32) 불일치로 인한 SSH 접속 타임아웃

| 항목 | 상세 내용 |
|---|---|
| **증상 (문제 상황)** | EC2 인스턴스(`mission-web-server`) 생성 후 `ssh -i mission-key.pem ubuntu@<퍼블릭IP>` 실행 시 수십 초 동안 반응이 없다가 `ssh: connect to host <퍼블릭IP> port 22: Operation timed out` 오류 발생 |
| **원인 가설** | 1. Security Group 인바운드 규칙에 22번 포트가 누락되었거나 소스 IP가 이전 접속 환경 IP로 잘못 고정되어 있음<br>2. EC2 인스턴스 내부의 `sshd` 데몬이 미실행 상태이거나 부팅 중임<br>3. 인스턴스에 퍼블릭 IPv4 주소(또는 Elastic IP)가 연결되지 않음 |
| **검증 방법** | 1. AWS CLI로 현재 적용된 보안 그룹 인바운드 규칙 조회:<br>`aws ec2 describe-security-groups --group-names mission-web-sg --query 'SecurityGroups[*].IpPermissions'` 실행 결과 기존 설정된 소스 IP(`203.0.113.10/32`)가 출력됨<br>2. 로컬 터미널에서 현재 나의 실제 공인 IP 조회:<br>`curl -s https://api.ipify.org` 결과 `121.135.181.35`로 확인되어 보안 그룹 허용 IP와 불일치 확인 |
| **조치 내용** | 불일치한 기존 22번 포트 규칙을 삭제하고, 현재 클라이언트 공인 IP 단일 호스트(`/32`)를 허용하는 인바운드 규칙으로 교체 등록:<br>`aws ec2 revoke-security-group-ingress --group-id <SG_ID> --protocol tcp --port 22 --cidr 203.0.113.10/32`<br>`aws ec2 authorize-security-group-ingress --group-id <SG_ID> --protocol tcp --port 22 --cidr 121.135.181.35/32` |
| **결과** | 명령 실행 즉시 SSH 연결 핸드셰이크가 성립하며 `ubuntu@ip-10-0-1-xx:~$` 프롬프트로 정상 로그인 완료 |
| **재발 방지** | 1. 수동으로 IP를 입력할 때 발생하는 오타 및 유동 IP 변동 문제를 방지하기 위해 `scripts/setup-aws.sh`에 `MY_IP="$(curl -s https://api.ipify.org)/32"`를 자동 주입하도록 구성<br>2. 인프라 배포 전 체크리스트에 "현재 공인 IP 일치 여부 확인" 절차를 명문화 |

### 검증 및 조치 터미널 로그
```bash
$ aws ec2 describe-security-groups --group-ids sg-0a1b2c3d4e5f6g7h8 \
    --query 'SecurityGroups[0].IpPermissions[?ToPort==`22`].IpRanges[0].CidrIp' --output text
203.0.113.10/32

$ curl -s https://api.ipify.org
121.135.181.35

$ aws ec2 authorize-security-group-ingress --group-id sg-0a1b2c3d4e5f6g7h8 \
    --protocol tcp --port 22 --cidr 121.135.181.35/32
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0123456789abcdef0",
            "GroupId": "sg-0a1b2c3d4e5f6g7h8",
            "GroupOwnerId": "902916048252",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "CidrIpv4": "121.135.181.35/32"
        }
    ]
}

$ ssh -i ~/.ssh/mission-key.pem ubuntu@43.201.77.88
Welcome to Ubuntu 22.04.5 LTS (GNU/Linux 6.8.0-1017-aws aarch64)
ubuntu@ip-10-0-1-15:~$
```

---

<a id="case-2"></a>
## 사례 2 — 서브넷 라우팅 테이블(0.0.0.0/0 → IGW) 누락으로 인한 외부 접속 차단

| 항목 | 상세 내용 |
|---|---|
| **증상 (문제 상황)** | 보안 그룹에서 HTTP(80)를 `0.0.0.0/0`으로 허용하고 Elastic IP를 할당했음에도, 외부 브라우저 접속 및 `curl http://<퍼블릭IP>` 호출 시 무한 로딩 후 `Connection timed out` 발생 |
| **원인 가설** | 1. VPC에 Internet Gateway가 연결(Attach)되지 않았음<br>2. Public Subnet에 연결된 Route Table에 기본 라우트(`0.0.0.0/0 → igw-xxxx`)가 누락되어 패킷이 외부 인터넷으로 나가지 못함 |
| **검증 방법** | 1. 서브넷에 연결된 라우팅 테이블 조회:<br>`aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=<SUBNET_ID>"`<br>2. 결과 확인: `10.0.0.0/16 local` 경로만 존재하고 `0.0.0.0/0` 라우트가 누락되어 있음을 확인 |
| **조치 내용** | 1. Internet Gateway가 VPC에 정상 Attach 되었는지 확인:<br>`aws ec2 attach-internet-gateway --internet-gateway-id <IGW_ID> --vpc-id <VPC_ID>`<br>2. 라우팅 테이블에 인터넷 방향 기본 경로 추가:<br>`aws ec2 create-route --route-table-id <RTB_ID> --destination-cidr-block 0.0.0.0/0 --gateway-id <IGW_ID>` |
| **결과** | 라우트 추가 즉시 외부 브라우저 및 `curl -i http://<퍼블릭IP>`에서 `HTTP/1.1 200 OK` 정상 응답 수신 |
| **재발 방지** | 퍼블릭 서브넷 생성 시 반드시 "IGW 생성 → VPC 연결 → 라우팅 테이블 0.0.0.0/0 등록 → 서브넷 연결(Associate)" 4단계를 체인 형태로 자동 실행하도록 배포 스크립트에 고정 |

### 검증 및 조치 터미널 로그
```bash
# 라우팅 테이블 조회: 로컬 경로만 존재 확인
$ aws ec2 describe-route-tables --route-table-ids rtb-0123456789abcdef0 \
    --query 'RouteTables[0].Routes' --output table
--------------------------------------------------
|                 DescribeRouteTables            |
+------------------+-----------------------------+
| DestinationCidr  |           Target            |
+------------------+-----------------------------+
| 10.0.0.0/16      | local                       |
+------------------+-----------------------------+

# 0.0.0.0/0 -> IGW 경로 추가
$ aws ec2 create-route --route-table-id rtb-0123456789abcdef0 \
    --destination-cidr-block 0.0.0.0/0 --gateway-id igw-0987654321fedcba0
{
    "Return": true
}

# 외부 curl 접속 즉시 성공
$ curl -sI http://43.201.77.88
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Content-Type: text/html
```

---

<a id="case-3"></a>
## 사례 3 — Nginx 프로세스 충돌 및 /health 경로 404 오류 해결

| 항목 | 상세 내용 |
|---|---|
| **증상 (문제 상황)** | 웹 서버 배포 후 메인 페이지(`http://<퍼블릭IP>/`)는 정상 열리지만, 과제 필수 요구사항인 `GET http://<퍼블릭IP>/health` 호출 시 `404 Not Found` 오류가 반환됨 |
| **원인 가설** | 1. Nginx 기본 설정(`/etc/nginx/sites-available/default`) 파일 내에 `/health` 경로를 처리하는 `location` 블록이 누락됨<br>2. 신규 설정 파일(`nginx.conf`)을 추가했으나 기존 `default` 가상 호스트와 포트 80 충돌이 발생하여 신규 설정이 반영되지 않음 |
| **검증 방법** | 1. EC2 내부에서 `curl -i http://localhost/health` 실행 시 `HTTP/1.1 404 Not Found` 확인<br>2. Nginx 활성 가상 호스트 검사: `nginx -T | grep -E "server_name|location /health"` 실행 결과 기본 default 사이트가 80번 포트를 선점하고 있음을 확인 |
| **조치 내용** | 1. 기본 default 사이트 심볼릭 링크 비활성화: `sudo rm -f /etc/nginx/sites-enabled/default`<br>2. `/etc/nginx/conf.d/ilikeaws.conf`에 `/health` 엔드포인트를 고정 텍스트 `"OK\n"`와 `200` 코드로 반환하도록 구성:<br>```nginx<br>location = /health {<br>    default_type text/plain;<br>    return 200 "OK\n";<br>}```<br>3. 문법 검사 후 리로드: `sudo nginx -t && sudo systemctl restart nginx` |
| **결과** | `curl -i http://localhost/health` 및 외부 `curl -i http://<퍼블릭IP>/health` 모두 `HTTP/1.1 200 OK` 및 바디 `OK` 정상 반환 확인 |
| **재발 방지** | EC2 User Data 스크립트 작성 시 `default` 설정을 자동 백업/제거하고, 단일 설정 파일에 `/`와 `/health`를 함께 선언하여 초기 부팅 시 자동 설정 완료되도록 표준화 |

### 검증 및 조치 터미널 로그
```bash
$ curl -i http://43.201.77.88/health
HTTP/1.1 404 Not Found
Server: nginx/1.18.0 (Ubuntu)

$ sudo rm -f /etc/nginx/sites-enabled/default
$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

$ sudo systemctl restart nginx

$ curl -i http://43.201.77.88/health
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Content-Type: text/plain
Content-Length: 3

OK
```

---

<a id="case-4"></a>
## 사례 4 — IAM 최소권한 적용 중 ec2:RunInstances 세부 액션 누락 및 보안 격리 검증

| 항목 | 상세 내용 |
|---|---|
| **증상 (문제 상황)** | 제약 사항(AdministratorAccess 금지)을 준수하기 위해 커스텀 IAM 정책(`mission-deployer`)을 작성하여 적용했으나, EC2 인스턴스 생성 시 `Client.UnauthorizedOperation: You are not authorized to perform this operation. (ec2:RunInstances)` 오류 발생 |
| **원인 가설** | `ec2:RunInstances` 작업은 단일 API 호출이지만, 내부적으로 서브넷 연결, 보안 그룹 바인딩, 키페어 참조, 볼륨 생성(`ec2:CreateVolume`), 태그 부여(`ec2:CreateTags`) 등의 연관 API 권한을 동시에 요구함 |
| **검증 방법** | AWS CloudTrail 이벤트 로그를 조회하여 실패한 `RunInstances` 호출의 `errorMessage` 내 필요 누락 액션 확인 |
| **조치 내용** | 1. 관리자 권한(`*`)을 남용하지 않고, 인스턴스 실행에 필수적인 연관 액션(`ec2:CreateTags`, `ec2:DescribeImages`, `ec2:DescribeKeyPairs`, `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`)을 정확히 화이트리스트에 추가<br>2. 동시에 보안 강화를 위해 무관한 서비스(`s3:*`, `rds:*`, `dynamodb:*`, `iam:Create*`)에 대한 명시적 거부(`Deny`) 정책을 병기<br>3. 배포 계정으로 `aws s3 ls` 실행 시 `AccessDenied`로 정상 차단됨을 확인하여 최소권한 격리 검증 |
| **결과** | 배포 계정(`mission-deployer`)으로 EC2, VPC, SG 프로비저닝이 완벽하게 동작하면서도 타 클라우드 리소스 침해 불가능 상태 달성 |
| **재발 방지** | 복잡한 IAM 정책을 수동 작성하기보다 검증된 최소권한 템플릿(`iam/minimal-deployer-policy.json`)을 저장소에 형상 관리하여 재사용 |

### IAM 보안 격리 검증 터미널 로그
```bash
# 최소권한 적용 후 EC2 조회 정상 동작
$ aws ec2 describe-instances --region ap-northeast-2 --output text | head -n 3
RESERVATIONS    902916048252    r-0123456789abcdef0

# 무관한 서비스(S3) 호출 시 명시적 거부(Deny) 차단 확인
$ aws s3 ls
An error occurred (AccessDenied) when calling the ListBuckets operation: Access Denied.
```
