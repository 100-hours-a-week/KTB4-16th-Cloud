# 워커 가입·라벨·테인트를 먼저 구성하는 순서

대상은 **kubeadm 1.36.6, Calico를 설치한 CP1, 설치를 마치고 아직 가입하지 않은 워커**다. 기존 Helm 차트는 `~/Desktop/mulo`에 있다.

이 문서의 순서는 **역할 결정 → 토큰 확인 → 워커 가입·label·taint 등록 → 전체 워커 확인 → Helm 배포 준비 → 이후 ASG 자동 가입 연결**이다. 명령은 실행 장소별로 구분했다. 필요한 Terraform 코드는 반영했다. 이 문서에서 직접 코드를 수정할 필요는 없다. AWS 적용은 6절의 검토·적용 명령으로 진행한다.

## 1. 워커의 역할과 배치 기준부터 정한다

기존 Helm 차트가 사용하는 `workload`를 노드 역할의 기준 라벨로 사용한다. 이 순서에서는 네 종류 모두 전용 taint를 적용한다.

| 역할 | Node label | Node taint | 배치할 Pod |
|---|---|---|---|
| system | `workload=system` | `dedicated=system:NoSchedule` | 운영 도구 |
| general | `workload=general` | `dedicated=general:NoSchedule` | 일반 앱·Envoy 데이터 플레인 |
| chat | `workload=chat` | `dedicated=chat:NoSchedule` | 채팅 |
| ai | `workload=ai` | `dedicated=ai:NoSchedule` | AI |

- **label**은 어떤 역할의 노드인지 나타낸다. Pod의 `nodeSelector`가 이 값을 선택한다.
- **taint**는 대응하는 `toleration`이 없는 Pod의 신규 배치를 제한한다. `NoSchedule`은 이미 실행 중인 Pod를 내보내는 설정은 아니다.
- **toleration**만 있어서는 해당 노드로 배치를 강제하지 않는다. `nodeSelector`와 함께 사용한다.

taint는 Pod 배치 제어다. Secret 조회 권한이나 AWS 접근 권한을 대신 제한하지 않으며, 그 권한은 RBAC·IAM으로 관리한다.

현재 AWS의 일반 워커에는 `api`라는 기존 이름이 남아 있다. `Role=api`, `mulo-v3-prod-api-ap-northeast-2a`가 이 문서의 **general 워커**다. Kubernetes 역할은 general로 정한다. 기존 Terraform의 `api` 키나 ASG 이름을 바로 바꾸면 교체 계획이 생길 수 있으므로, 리소스 이름 변경과 노드 역할 설정을 구분한다.

## 2. CP1에서 가입 토큰이 준비됐는지 확인한다

**실행 장소: CP1에 접속한 터미널.** 워커에서는 토큰을 발급하지 않는다.

```bash
# CP1 관리자 셸로 전환한다.
sudo -i

# 이후 kubectl이 CP1의 관리자 접속 정보를 사용하게 한다. 이 파일을 워커나 Git에 복사하지 않는다.
export KUBECONFIG=/etc/kubernetes/admin.conf

# API 서버가 준비됐는지 확인한다. 정상 응답은 ok다.
kubectl get --raw='/readyz'

# 이미 가입된 노드의 이름·사설 IP·역할을 확인한다.
kubectl get nodes -o wide -L workload

# 기존 토큰 게시 스크립트가 있는지 확인한다.
ls -l /usr/local/sbin/publish-worker-join.sh
```

게시 스크립트가 없거나 이전 JSON 오류가 해결되지 않았다면 **문서 끝의 부록 A**를 먼저 따른다. 이미 정상 작동한다면 덮어쓰지 않고 다음 확인만 한다.

```bash
# CP1에서 새 가입 토큰을 발급하고 SSM에 게시한다.
/usr/local/sbin/publish-worker-join.sh

# 토큰 자체는 출력하지 않고, 가입 주소와 남은 유효시간만 확인한다.
aws ssm get-parameter --region ap-northeast-2 \
  --name /mulo-v3-prod/join/worker --with-decryption \
  --query Parameter.Value --output text \
  | jq '{apiServerEndpoint,remainingSeconds:(.expiresAt-now|floor)}'

# 토큰 자동 게시 타이머의 다음 실행 시각을 확인한다.
systemctl list-timers mulo-worker-token.timer --all
```

`remainingSeconds`가 **900보다 커야** 다음 가입 스크립트가 진행한다. `ParameterNotFound`는 CP의 SSM 게시가 아직 성공하지 않았거나 계정·리전·이름이 다른 경우다. 워커를 먼저 가입시켜야 해결되는 오류가 아니다.

토큰은 발급 후 24시간이 지나면 만료된다. CP가 6시간마다 새 토큰을 발급·게시하고 이전 토큰은 원래 만료 시각까지 유지한다. **이미 가입한 워커는 이후 kubelet 인증서를 사용하므로 가입 토큰 만료 때 재가입하지 않는다.**

## 3. 사용할 기존 워커를 역할에 맞춰 가입시킨다

기존 EC2를 계속 사용할 것이면 가입시킨다. 새 EC2로 대체할 서버까지 모두 가입할 필요는 없다. 단, ASG는 아직 Kubernetes에 가입하지 않은 EC2도 현재 인스턴스 대수에 포함한다.

**아래 가입 블록은 CP1이 아니라 가입시킬 워커의 터미널에서 실행한다.** 이미 `/etc/kubernetes/kubelet.conf`가 있거나 CP1의 Node 목록에 해당 서버가 있다면 가입 명령을 반복하지 않고 4절에서 상태를 확인한다. `kubeadm reset`이나 인증서 삭제를 먼저 실행하지 않는다.

워커 AMI에는 containerd·kubeadm·kubelet을 준비하고 swap을 비활성화한다. Kubernetes 버전은 CP1과 같은 1.36.6을 기준으로 확인한다. 새 ASG 노드는 User Data가 AWS CLI·jq·curl·CA 인증서 중 없는 도구를 자동 설치한다. 아래처럼 기존 EC2를 직접 가입시킬 때는 그 서버에도 도구가 있어야 한다. AMI는 가입 전 상태로 만든 기존 이미지를 사용한다. 원본 EC2를 나중에 가입시켜도 이미 만들어 둔 AMI는 바뀌지 않는다.

기존 워커에서 `aws: command not found`가 나오면 **그 워커에서** 먼저 설치한다. AWS 액세스 키를 입력할 필요는 없으며 EC2의 IAM 역할을 사용한다.

```bash
# 기존 워커의 패키지 목록을 갱신하고 가입에 필요한 도구를 설치한다.
sudo apt-get update
sudo apt-get install -y awscli jq curl ca-certificates
# 설치 결과를 확인한다.
aws --version
```

### 3.1. 실행할 역할을 고른다

**실행 장소: 가입시킬 워커의 터미널.** 먼저 역할을 변수에 저장한다. 아래 예시는 general 워커다. 다른 워커에서는 오른쪽 역할 값만 바꾼다.

| 접속한 워커 | WORKER_ROLE에 넣을 값 |
|---|---|
| system | system |
| general, 기존 AWS Role=api 서버 | general |
| chat | chat |
| ai | ai |

```bash
# 이 서버를 general 워커로 가입시키겠다는 값을 현재 터미널에 저장한다.
# 이 한 줄만으로 가입되지는 않는다.
WORKER_ROLE=general
```

명령 앞뒤에 백틱(`)이나 `root@...#` 프롬프트를 붙이지 않는다. 새 터미널을 열었다면 역할 변수도 다시 지정한다.

### 3.2. 가입하면서 label·taint도 함께 등록한다

**실행 장소: 3.1에서 역할을 지정한 같은 워커 터미널.** 아래 코드 블록을 **전체 복사**해 실행한다. 시작 줄만 따로 실행하지 않는다. 마지막 줄의 `BASH`도 포함해야 한다. 토큰을 사람이 복사하거나 Helm 차트에 넣지 않는다.

`<<'BASH'`는 다음 줄부터 마지막 `BASH` 직전까지를 실행할 스크립트로 읽으라는 뜻이다. `wanted BASH` 경고는 이 전체 입력이 전달되지 않았다는 뜻이다.

```bash
# 3.1에서 지정한 역할을 전달한다. 아래부터 마지막 BASH까지 모두 함께 실행한다.
sudo bash -s -- "$WORKER_ROLE" <<'BASH'
# 명령 실패·정의되지 않은 변수·파이프 실패가 있으면 중단한다.
set -euo pipefail
# 임시 가입 설정과 로그를 root만 읽게 한다. 명령 추적(set -x)은 켜지 않는다.
umask 077
export AWS_PAGER=""
ROLE="$1"
REGION="ap-northeast-2"
PARAMETER="/mulo-v3-prod/join/worker"

# 오타가 난 역할로 가입하지 않는다.
case "$ROLE" in system|general|chat|ai) ;; *) echo '역할을 확인하세요.' >&2; exit 1 ;; esac
# CP나 이미 가입을 진행한 서버에서는 실행하지 않는다.
if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/kubelet.conf ]]; then
  echo 'CP 또는 가입 이력이 있는 서버입니다. CP1의 Node 목록부터 확인하세요.' >&2
  exit 1
fi
# 필요한 프로그램이 없으면 설치 준비 단계부터 완료한다.
for TOOL in aws jq curl kubeadm kubelet; do command -v "$TOOL" >/dev/null; done
# 이 문서의 CP1 기준 버전과 일치하지 않으면 가입을 멈추고 버전을 확인한다.
test "$(kubeadm version -o short)" = "v1.36.6"
test "$(kubelet --version)" = "Kubernetes v1.36.6"
# containerd가 실행 중이고 swap이 꺼져 있어야 한다.
systemctl is-active --quiet containerd
test -z "$(swapon --show --noheadings)"

# IMDSv2에서 이 EC2 자신의 정보를 읽을 임시 토큰을 받는다. Kubernetes 토큰과는 다르다.
IMDS_TOKEN="$(curl -fsS --connect-timeout 3 --max-time 10 -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
  http://169.254.169.254/latest/api/token)"
IDENTITY="$(curl -fsS --connect-timeout 3 --max-time 10 \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/dynamic/instance-identity/document)"
# Node 이름·AZ·사설 IP를 이 서버의 실제 값으로 정한다.
INSTANCE_ID="$(jq -er '.instanceId' <<< "$IDENTITY")"
AZ="$(jq -er '.availabilityZone' <<< "$IDENTITY")"
NODE_IP="$(jq -er '.privateIp' <<< "$IDENTITY")"

# 워커의 인스턴스 IAM 역할로 SSM의 최신 가입 정보를 읽는다. aws configure로 키를 넣지 않는다.
BUNDLE="$(aws ssm get-parameter --region "$REGION" --name "$PARAMETER" \
  --with-decryption --query Parameter.Value --output text)"
# 만료까지 15분 이상 남은 값인지 확인한다. 값 자체는 출력하지 않는다.
jq -e '(.expiresAt > now+900) and (.token|type=="string") and
  (.caCertHash|test("^sha256:[a-f0-9]{64}$"))' <<< "$BUNDLE" >/dev/null

# 가입 설정은 /run의 임시 파일에만 저장하고 성공·실패 시 모두 지운다.
JOIN_FILE="$(mktemp /run/mulo-worker-join.XXXXXX)"
trap 'rm -f "$JOIN_FILE"' EXIT
# JSON도 kubeadm 설정으로 읽을 수 있다. 실제 토큰은 SSM에서 읽은 값으로 채운다.
jq --arg role "$ROLE" --arg id "$INSTANCE_ID" --arg az "$AZ" \
  --arg region "$REGION" --arg ip "$NODE_IP" '
  {
    apiVersion:"kubeadm.k8s.io/v1beta4",
    kind:"JoinConfiguration",
    discovery:{bootstrapToken:{
      apiServerEndpoint:.apiServerEndpoint,token:.token,caCertHashes:[.caCertHash]
    }},
    nodeRegistration:{
      name:$id,
      criSocket:"unix:///run/containerd/containerd.sock",
      # 네 역할 모두 해당 역할의 toleration이 있는 Pod만 새로 배치하도록 제한한다.
      taints:[{key:"dedicated",value:$role,effect:"NoSchedule"}],
      kubeletExtraArgs:[
        # 기존 Helm 차트가 사용하는 workload 라벨을 가입 때부터 등록한다.
        {name:"node-labels",value:("workload="+$role+
          ",topology.kubernetes.io/zone="+$az+
          ",topology.kubernetes.io/region="+$region)},
        # CA가 Kubernetes Node와 실제 EC2를 연결할 식별값이다.
        {name:"provider-id",value:("aws:///"+$az+"/"+$id)},
        {name:"node-ip",value:$ip}
      ]
    }
  }' <<< "$BUNDLE" > "$JOIN_FILE"

# 실제 가입을 실행한다. 출력은 root 전용 로그에 저장한다.
if ! kubeadm join --config "$JOIN_FILE" > /run/mulo-worker-join.log 2>&1; then
  echo '가입 실패: 이 워커의 /run/mulo-worker-join.log를 확인하세요.' >&2
  exit 1
fi
# 성공 시 역할과 Node 이름만 출력한다.
echo "가입 완료: workload=$ROLE node=$INSTANCE_ID"
BASH
```

system 가입 후 CP1에서 확인하고, general → chat → ai도 같은 방식으로 진행한다. 가입 후 다시 워커 AMI를 만들지 않는다. Calico도 워커마다 재설치하지 않는다.

## 4. CP1에서 전체 워커의 label·taint를 확인한다

**실행 장소: CP1.** 먼저 사용할 워커가 모두 Ready인지 확인한다.

```bash
# Node 이름·사설 IP·역할을 확인한다.
kubectl get nodes -o wide -L workload

# 해당 EC2 연결 정보와 역할별 taint를 확인한다.
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,PROVIDER:.spec.providerID,TAINTS:.spec.taints'

# Calico·kube-proxy·CoreDNS 등 기본 Pod 상태를 확인한다.
kubectl get pods -A -o wide
```

3절로 새로 가입했다면 역할 설정도 함께 등록되므로 `kubectl label`·`kubectl taint`를 다시 실행할 필요가 없다.

**이미 가입한 워커에 역할이 없거나 다른 경우에만** 아래를 CP1에서 실행한다. Node 이름은 위 출력의 실제 이름으로 바꾼다. system/general/chat/ai 각각 해당하는 서버를 지정한다.

```bash
# 이미 가입한 특정 워커의 이름과 그 서버가 맡을 역할을 지정한다.
NODE_NAME="REPLACE_WITH_ACTUAL_NODE_NAME"
ROLE="system"

# 이 Node가 어떤 EC2인지 이름·사설 IP부터 확인한다.
kubectl get node "$NODE_NAME" -o wide

# workload 라벨을 지정하고 해당 역할의 전용 taint를 추가·갱신한다.
# 다른 키의 taint나 CP taint를 일괄 삭제하는 명령이 아니다.
kubectl label node "$NODE_NAME" "workload=$ROLE" --overwrite
kubectl taint node "$NODE_NAME" "dedicated=$ROLE:NoSchedule" --overwrite

# 적용 결과를 확인한다.
kubectl describe node "$NODE_NAME"
```

이미 실행 중인 잘못 배치된 Pod는 `NoSchedule`을 추가해도 그대로 남을 수 있다. 기존 Pod의 위치를 확인한 뒤 재배치 여부를 별도로 정한다. CP의 기본 taint는 제거하지 않는다.

확인 기준은 다음과 같다.

- 사용할 워커가 모두 Ready이며 1절 표와 일치한다.
- providerID가 `aws:///<AZ>/<인스턴스 ID>` 형식이다. 이미 가입한 노드에 값이 없다면 기존 kubelet의 provider-id 설정도 확인한다.
- Calico·kube-proxy·로그 에이전트 같은 DaemonSet은 각 노드 taint를 허용해야 한다.
- CoreDNS를 system에 배치한다면 기존 tolerations를 보존하면서 system toleration을 추가한다. taint 때문에 DNS나 네트워크 에이전트가 Pending이면 앱 배포보다 먼저 해결한다.

가입 실패는 **실패한 워커에서** 다음 명령으로 확인한다.

```bash
# 가입 명령까지 진행했다면 이 로그에 실패 이유가 있다. 토큰 포함 여부를 확인하고 공유한다.
sudo cat /run/mulo-worker-join.log
# kubelet의 최근 로그를 확인한다.
sudo journalctl -u kubelet -n 80 --no-pager
```

## 5. 그다음 기존 Helm 차트의 배치 조건을 확인한다

기존 차트는 `~/Desktop/mulo`를 사용한다. 새 Helm 디렉터리나 복제본을 추가로 만들지 않는다. Helm 명령은 **차트 파일이 있고 API 서버에 접근할 수 있는 운영 터미널**에서 실행한다. 워커마다 Helm을 설치하는 작업은 아니다.

현재 차트의 배치 조건은 다음과 같다.

| 기존 파일 | 역할 |
|---|---|
| `system/argocd/values.yaml` 등의 운영 도구 values | `workload: system`, system toleration |
| `general/frontend/chart`, `general/backend/chart` | `workload: general`, general toleration |
| `system/gateway/chart`의 Envoy 데이터 플레인 | `workload: general`, general toleration |
| `chat/chart` | `workload: chat`, chat toleration |
| `ai/chart` | `workload: ai`, ai toleration |

예를 들어 general Pod의 설정은 아래와 같다. **기존 차트를 확인하기 위한 예시이며 새 리소스 파일로 추가하지 않는다.**

```yaml
# spec.template.spec 아래에 들어갈 Pod 배치 설정이다.
nodeSelector:
  workload: general
# general 노드의 전용 taint를 허용한다.
tolerations:
  - key: dedicated
    operator: Equal
    value: general
    effect: NoSchedule
```

**Helm 차트와 Git에는 배치·설정 구조를 두고 실제 비밀값은 넣지 않는다.** join token·AWS 액세스 키·DB 비밀번호·Vault 토큰·admin.conf·인증서 개인키를 저장하지 않는다. 앱의 비밀값은 Vault 등 외부 저장소에서 전달하고 차트에는 Secret 이름이나 외부 저장소의 참조만 둔다. Helm values의 실제 비밀값은 릴리스 기록에도 남을 수 있다.

노드와 배치 조건 확인 후에 실제 Helm 설치를 진행한다. 이 문서에서 Argo CD·Vault·모니터링 전체 설치를 한꺼번에 실행하지 않는다. 각 구성 요소의 IAM·시크릿·스토리지·이미지 준비가 끝난 것부터 기존 차트의 설치 절차를 따른다.

## 6. 반영된 자동 가입 설정을 AWS에 적용한다

코드는 수정돼 있다. 직접 HCL을 편집하는 단계는 없다. 이번 변경은 다음과 같다.

- 새 EC2에 AWS CLI·jq·curl·CA 인증서가 없으면 User Data가 자동 설치한다. 설치에는 Ubuntu·GitHub·Go 모듈 저장소·ECR로 나갈 수 있는 경로가 필요하다. ECR 실행 파일이 AMI에 없으면 첫 부팅의 빌드에 몇 분이 추가될 수 있다.
- 같은 User Data에 ECR 설치 스크립트를 압축해 포함했다. 실행 파일이 없으면 공식 소스를 빌드하고, EC2 IAM 역할의 ECR 인증을 확인한 뒤 kubelet 인증 설정을 저장한다. 가입 전에 kubelet을 재시작하지 않는다. Git의 최신 스크립트를 부팅 때 내려받는 구조가 아니다.
- 새 노드가 최신 SSM 토큰으로 가입하면서 `workload=system/general/chat/ai`와 `dedicated=<역할>:NoSchedule`를 등록한다.
- CA가 보는 ASG 예측 태그도 실제 label·taint와 같게 맞춘다.
- Calico는 설계(Cloud Wiki 5단계 3.5)대로 **VXLAN Always** 모드로 쓴다. 모든 Pod 패킷이 노드 IP의 UDP 4789로 감싸져 오가므로 source/destination check를 끌 필요가 없다. 예전 CrossSubnet용 source/dest check 해제 코드(CP 속성, 워커 IAM 정책, User Data)는 삭제했다. 클러스터 쪽 전환은 6.0절을 따른다.
- 초기 EBS CSI는 선택한 system EC2 역할을 사용한다. 운영 입력의 `ebs_csi_use_node_role=true`를 반영해 system 역할에만 AWS 공식 EBS CSI 정책을 연결했다. 다른 환경의 기본값은 false다.
- CP의 Typha에 접속할 수 있도록 **공통 노드 overlay 보안 그룹 → CP TCP 5473** 인바운드를 추가한다. 현재 Typha는 CP에서 실행 중이다.

기존 ASG 식별자·AMI·인스턴스 유형·노드 대수는 유지한다. 일반 워커의 Kubernetes 역할과 새 EC2 표시 태그는 general로 맞췄다. 기존 AWS ASG 이름에 남은 api는 리소스 교체를 피하기 위해 유지한다.

### 6.0. CP1에서 Calico를 VXLAN Always로 바꾼다

보안 그룹은 노드 사이에 UDP 4789만 연다. CrossSubnet 모드는 같은 서브넷 안의 Pod 패킷을 캡슐화하지 않고 Pod IP로 보내는데, 보안 그룹은 Pod IP를 어떤 규칙과도 일치시키지 않아 버린다. 그래서 Always로 바꾼다.

```bash
# 실행 장소: CP1. 현재 모드를 확인한다. VXLANCrossSubnet이면 바꿔야 한다.
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.ipPools[*].encapsulation}{"\n"}'
kubectl get ippool -o custom-columns='NAME:.metadata.name,CIDR:.spec.cidr,VXLAN:.spec.vxlanMode'

# Tigera operator로 설치했다면 Installation의 encapsulation을 VXLAN으로 바꾼다.
# 편집기에서 ipPools 항목의 encapsulation: VXLANCrossSubnet → VXLAN 한 줄만 고친다.
kubectl edit installation default

# operator가 IPPool을 바꿨는지 확인한다. vxlanMode가 Always여야 한다.
kubectl get ippool -o custom-columns='NAME:.metadata.name,VXLAN:.spec.vxlanMode'
```

이미 떠 있는 연결은 끊기지 않고, 새 패킷부터 캡슐화된다. 바꾼 뒤 ESO webhook과 chat → ai-api 호출을 다시 확인한다.

이미 source/destination check를 끈 EC2가 있으면 다시 켠다. 켜 두는 게 기본값이고 더 안전하다.

```bash
# 실행 장소: 로컬 Mac. false로 바뀐 클러스터 EC2를 찾는다.
AWS_PROFILE=mulo-prod aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:kubernetes.io/cluster/mulo-v3-prod,Values=owned \
  --query 'Reservations[].Instances[?SourceDestCheck==`false`].InstanceId' --output text
# 나온 ID마다 다시 켠다.
AWS_PROFILE=mulo-prod aws ec2 modify-instance-attribute --region ap-northeast-2 \
  --instance-id <인스턴스-ID> --source-dest-check
```

### 6.1. 로컬 Mac에서 계획을 검토하고 적용한다

**실행 장소: 로컬 Mac, `~/Desktop/v3-terraform`.** 이전에 만든 plan은 재사용하지 않는다.

이번 코드는 기존 EC2의 수동 ECR 설정을 자동으로 실행하지 않는다. **이미 가입한 워커 4대는 Helm 저장소 `mulo/README.md`의 2번 설치 스크립트를 각각 실행한다. CP1에서 실행하지 않는다.** 아래 plan은 이후 생성되는 노드의 자동 가입·ECR 준비 설정을 검토하는 단계다. 실제 AWS 상태에 따라 변경 개수가 달라질 수 있으므로 새 계획에서 EC2 교체·삭제가 없는지 확인한다.

예전에 만든 `calico-routing.tfplan`은 CrossSubnet용 계획이라 **적용하지 않고 지운다.** 새로 plan을 만든다.

**ESO 웹훅이 CP3에서만 timeout인 경우:** CP3와 system 워커가 같은 서브넷(2c)이라 CrossSubnet 모드에서 패킷이 캡슐화 없이 Pod IP로 오갔고, AWS가 이를 버렸다. 6.0절대로 VXLAN Always로 바꾸면 해결된다. 같은 이유로 chat(2b)에서 ai-api(2b)로 가는 호출도 막혀 있었다.

**Vault가 Pending이고 EBS CSI가 없다면:** Helm 저장소 `mulo/README.md`의 “스토리지 1~4”를 따른다. 현재 system EC2의 IMDS 설정은 Launch Template 변경만으로 바뀌지 않으므로 그 문서의 Mac 명령을 별도로 실행해야 한다. CSI 설치·PVC Bound 확인·Vault init은 CP1에서 진행한다.

```bash
# Terraform 저장소로 이동한다.
cd ~/Desktop/v3-terraform
# 현재 코드와 AWS 상태로 새 계획을 만든다. AWS 리소스를 변경하는 명령은 아니다.
AWS_PROFILE=mulo-prod terraform -chdir=environments/prod plan \
  -input=false -lock-timeout=30s -out=review.tfplan
# 추가·변경 대상과 EC2 교체·삭제 여부를 확인한다.
AWS_PROFILE=mulo-prod terraform -chdir=environments/prod show review.tfplan
```

검토한 계획을 AWS에 반영할 때만 다음 명령을 실행한다. 저장된 계획 적용에는 별도 yes 질문이 없다.

```bash
# 실행 장소: 같은 로컬 Mac. 여기서 검토한 변경이 실제 AWS에 적용된다.
AWS_PROFILE=mulo-prod terraform -chdir=environments/prod apply review.tfplan
```

### 6.2. 먼저 기존 워커의 Calico 회복을 확인한다

기존 워커에서 Typha TCP 5473 timeout이 확인됐다. 보안 그룹 규칙 적용 후 **CP1에서** 확인한다. 가입이나 workload 설정을 다시 할 필요는 없다.

```bash
# Calico가 자동 재접속해 모든 노드에서 1/1이 되는지 확인한다. Ctrl+C는 감시만 끝낸다.
kubectl -n calico-system get pods -l k8s-app=calico-node -o wide -w
```

감시를 끝낸 뒤 다음을 확인한다.

```bash
# 모든 노드가 Ready인지 확인한다.
kubectl get nodes -o wide -L workload
# network-unavailable이 사라지고 역할별 dedicated taint가 남아 있는지 확인한다.
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

5473 접속 복구 뒤에도 `goldmane:7443` 경고나 다른 실패가 남으면 해당 로그를 추가 확인한다. network-unavailable taint를 수동 삭제해 정상으로 보이게 만들지 않는다.

### 6.3. 새 ASG 노드 한 대의 자동 가입을 확인한다

User Data 변경은 이후 새로 생성되는 EC2에 적용된다. 기존 EC2를 자동 재설치하거나 교체하는 설정은 추가하지 않았다.

**AWS 콘솔:** EC2 → Auto Scaling 그룹 → `mulo-v3-prod-system-ap-northeast-2c` → 인스턴스 관리에서 기존 ID 기록 → 그룹 크기 편집. 현재 desired=1·max=2일 때 desired만 2로 올려 새 인스턴스 한 대를 만든다. 이미 2대라면 먼저 두 서버의 가입 상태를 확인한다.

**CP1:** `kubectl get nodes -w`로 새 인스턴스 ID의 Node가 자동 등록되는지 보고, 4절의 workload·taint·Ready를 확인한다. 새 EC2가 최신 Launch Template과 준비한 워커 AMI를 사용하는지도 확인한다. 실패하면 **새 워커에서** 다음을 조회한다.

```bash
# 도구 설치·ECR 준비·SSM 읽기·가입 전 검사 중 어디서 실패했는지 확인한다.
sudo tail -n 80 /var/log/cloud-init-output.log
# 실제 join 명령까지 진행됐다면 이 로그도 확인한다.
sudo cat /run/mulo-worker-join.log
```

시험 뒤 desired를 내리면 ASG가 종료 대상을 선택한다. 새 노드만 자동으로 정리된다고 가정하지 않는다. 이 절차에서는 노드 종료·instance refresh를 실행하지 않는다.

CA는 system 워커가 먼저 준비된 뒤 실행한다. 현재 CA values의 IRSA 역할 ARN만으로 AWS 권한이 생기지는 않는다. 실제 IAM 인증을 준비하고, 최초에는 scale-down을 끈 상태로 증설부터 확인한다. Pod가 들어갈 자리가 부족하면 CA가 ASG desired를 늘리고, 새 EC2가 위 User Data로 가입하는 구조다.

## 부록 A. CP1의 토큰 게시가 아직 준비되지 않았을 때만

이미 2절에서 SSM 조회와 timer 확인이 성공했다면 이 부록은 건너뛴다. **실행 장소: CP1의 root 셸.** 스크립트에는 비밀값을 고정하지 않고 실행할 때 새 토큰을 발급한다.

```bash
# CP1에 토큰 게시 작업을 저장한다. 같은 파일이 있으면 덮어쓰므로 기존 정상 설정은 유지한다.
tee /usr/local/sbin/publish-worker-join.sh >/dev/null <<'SCRIPT'
#!/bin/bash
# 실패하면 중단하고, 임시 파일은 root만 읽게 한다.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export AWS_PAGER=""
REGION="ap-northeast-2"
PARAMETER="/mulo-v3-prod/join/worker"
# 워커가 접속할 현재 내부 API NLB 주소다. https://는 붙이지 않는다.
API_ENDPOINT="mulo-v3-prod-api-779e286b32b8d09d.elb.ap-northeast-2.amazonaws.com:6443"
# SSM 요청은 /dev/stdin 대신 실제 임시 JSON 파일로 전달한다.
REQUEST_FILE="$(mktemp /run/mulo-worker-request.XXXXXX)"
trap 'rm -f "$REQUEST_FILE"' EXIT
ISSUED_AT="$(date +%s)"
EXPIRES_AT="$((ISSUED_AT + 86400))"
# CP의 admin.conf로 24시간짜리 토큰을 발급한다. admin.conf 자체는 게시하지 않는다.
TOKEN="$(kubeadm token create --kubeconfig /etc/kubernetes/admin.conf \
  --ttl 24h --description mulo-worker-autojoin)"
# 신뢰할 클러스터 CA의 공개키 해시를 계산한다. 개인키는 읽거나 전달하지 않는다.
CA_HASH="sha256:$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -hex | awk '{print $NF}')"
# 가입 정보 다섯 개를 JSON 문자열로 묶어 SecureString 저장 요청을 만든다.
jq -n --arg name "$PARAMETER" --arg endpoint "$API_ENDPOINT" \
  --arg token "$TOKEN" --arg hash "$CA_HASH" \
  --argjson issued "$ISSUED_AT" --argjson expires "$EXPIRES_AT" \
  '{Name:$name,Type:"SecureString",KeyId:"alias/aws/ssm",Overwrite:true,
    Value:({apiServerEndpoint:$endpoint,token:$token,caCertHash:$hash,
            issuedAt:$issued,expiresAt:$expires}|tojson)}' > "$REQUEST_FILE"
# JSON을 검사하고 SSM에 게시한다. 토큰은 화면에 출력하지 않는다.
jq empty "$REQUEST_FILE"
aws ssm put-parameter --region "$REGION" --cli-input-json "file://$REQUEST_FILE" >/dev/null
echo "가입 정보 게시 완료: expiresAt=$EXPIRES_AT"
SCRIPT
# root만 읽고 실행하게 한다.
chmod 0700 /usr/local/sbin/publish-worker-join.sh
```

이어서 예약 실행을 등록한다.

```bash
# 한 번 실행하고 끝나는 CP1 토큰 게시 작업이다.
tee /etc/systemd/system/mulo-worker-token.service >/dev/null <<'UNIT'
[Unit]
Description=Publish worker join information to SSM
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/publish-worker-join.sh
TimeoutStartSec=300
UMask=0077
UNIT
# 부팅 후와 매일 00·06·12·18시에 실행한다. CP 호스트의 시간대를 따른다.
tee /etc/systemd/system/mulo-worker-token.timer >/dev/null <<'UNIT'
[Unit]
Description=Refresh worker join token every six hours
[Timer]
OnBootSec=2min
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=10min
Persistent=true
Unit=mulo-worker-token.service
[Install]
WantedBy=timers.target
UNIT
# 새 unit을 읽고 timer를 부팅 시에도 켜지게 한다.
systemctl daemon-reload
systemctl enable --now mulo-worker-token.timer
# 지금도 한 번 게시하고, 실행 결과와 다음 예약을 확인한다.
systemctl start mulo-worker-token.service
systemctl list-timers mulo-worker-token.timer --all
journalctl -u mulo-worker-token.service -n 20 --no-pager
```

CP 인스턴스 IAM에는 해당 경로의 `ssm:PutParameter`, 워커 IAM에는 `ssm:GetParameter`가 필요하다. 이 예시는 `alias/aws/ssm`을 사용한다. 고객 관리형 KMS 키를 사용하면 키 정책과 Encrypt·Decrypt 권한도 맞춰야 한다. 부록 완료 후 **2절의 비밀값을 출력하지 않는 조회**부터 다시 확인한다.

## 공식 문서

- [kubeadm 가입 설정: taints와 kubeletExtraArgs](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/#noderegistrationoptions)
- [Taint와 toleration](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [가입 토큰의 TTL](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/)
- [CA의 AWS 태그와 IAM](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md)
- [Helm 릴리스 기록과 민감정보](https://helm.sh/docs/topics/advanced/#storage-backends)
