# Control Plane 처음 세우기

`terraform apply` 직후의 빈 CP 3대에서 kubeadm 클러스터를 만드는 순서입니다. 워커는 ASG가 띄우고 User Data로 알아서 가입하므로, 여기서는 CP와 CNI까지만 합니다.

전제:

- CP AMI(`config.ami_id`)에 containerd, kubeadm·kubelet·kubectl 1.36.6이 설치돼 있고 swap이 꺼져 있다. 워커 AMI(`basic-ami-kube11/12`)를 같이 쓴다.
- CP 3대에 SSM Session Manager로 접속할 수 있다.
- Pod 대역은 `192.168.0.0/16`, Service 대역은 kubeadm 기본값 `10.96.0.0/12`. VPC(`10.60.0.0/16`)·GCP 이전 대역(`10.20.0.0/24`, `10.91.0.0/16`)과 겹치지 않는다.

## 0. 값 확인 (Mac)

```bash
cd ~/Desktop/v3-terraform
AWS_PROFILE=mulo-login terraform -chdir=environments/prod output -json compute | jq '.control_planes'
AWS_PROFILE=mulo-login terraform -chdir=environments/prod output -raw endpoints >/dev/null; \
AWS_PROFILE=mulo-login terraform -chdir=environments/prod output -json endpoints | jq -r '.api'   # 내부 NLB:6443
```

## 1. 모든 CP: etcd 전용 볼륨을 먼저 붙인다

새로 만드는 클러스터라 데이터를 옮길 필요 없이, init 전에 `/var/lib/etcd`에 마운트만 하면 됩니다. **CP 3대 각각**에서:

```bash
# Terraform이 /dev/sdf로 붙인 20GiB 볼륨. Nitro에서는 NVMe 이름으로 보인다.
lsblk -o NAME,SIZE,SERIAL,MOUNTPOINT
DEV=/dev/nvme1n1                     # 20G이고 마운트되지 않은 디스크로 바꾼다
sudo blkid "$DEV" && echo "이미 파일시스템이 있습니다. 멈추세요." || sudo mkfs.ext4 -L etcd "$DEV"
sudo mkdir -p /var/lib/etcd && sudo chmod 700 /var/lib/etcd
echo "UUID=$(sudo blkid -s UUID -o value "$DEV") /var/lib/etcd ext4 defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount /var/lib/etcd && df -h /var/lib/etcd
# 빈 lost+found만 있어야 한다. kubeadm은 비어 있지 않은 etcd 디렉터리를 거부하므로 지운다.
sudo rmdir /var/lib/etcd/lost+found
```

## 2. CP1: kubeadm init

```bash
API="<0단계의 NLB 주소>:6443"
NODE_IP="$(hostname -I | awk '{print $1}')"
cat <<EOC | sudo tee /root/kubeadm-init.yaml >/dev/null
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "$NODE_IP"
localAPIEndpoint:
  advertiseAddress: "$NODE_IP"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.6
clusterName: mulo-v3-prod
controlPlaneEndpoint: "$API"
networking:
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOC
sudo kubeadm init --config /root/kubeadm-init.yaml --upload-certs | tee ~/kubeadm-init.out
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

출력 끝의 **control-plane join 명령**(`--control-plane --certificate-key ...`)을 3단계에서 씁니다. certificate key는 2시간 뒤 만료됩니다. 만료됐으면 `sudo kubeadm init phase upload-certs --upload-certs`로 다시 받습니다. `~/kubeadm-init.out`에는 토큰이 들어 있으니 3단계 뒤 지웁니다.

## 3. CP2, CP3: control-plane으로 가입

각 CP에서 2단계 출력의 명령에 이 노드의 IP를 붙여 실행합니다. **한 대씩** 하고, 앞 노드가 Ready가 된 뒤 다음으로 넘어갑니다.

```bash
NODE_IP="$(hostname -I | awk '{print $1}')"
sudo kubeadm join <NLB>:6443 --token <...> \
  --discovery-token-ca-cert-hash sha256:<...> \
  --control-plane --certificate-key <...> \
  --apiserver-advertise-address "$NODE_IP"
```

CP1에서 확인:

```bash
kubectl get nodes -o wide                       # CP 3대 (CNI 전이라 NotReady가 정상)
kubectl -n kube-system get pods -l component=etcd -o wide
rm -f ~/kubeadm-init.out
```

## 4. CP1: Calico (VXLAN Always)

설계(Cloud Wiki 3.5)대로 VXLAN 오버레이를 **Always**로 씁니다. 보안 그룹이 노드 사이에 UDP 4789만 열기 때문에 CrossSubnet을 쓰면 같은 서브넷 Pod 통신이 막힙니다. AWS MTU 9001에서 VXLAN 헤더 50을 뺀 8951을 명시합니다.

```bash
CALICO=v3.33.0   # Kubernetes 1.35~1.37 지원(2026-11-15 구축에 사용)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml
cat <<EOC | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    # VXLAN 모드는 BGP가 필요 없다. 켜 두면(operator 기본값) BIRD가 TCP 179로 붙으려다
    # 보안 그룹에 막혀 calico-node가 전부 NotReady가 된다.
    bgp: Disabled
    mtu: 8951
    ipPools:
      - name: default-ipv4-ippool
        cidr: 192.168.0.0/16
        encapsulation: VXLAN
        natOutgoing: Enabled
        blockSize: 26
        nodeSelector: all()
  # 보안 그룹이 Typha 5473을 CP로만 열기 때문에 Typha는 CP에만 둔다.
  typhaDeployment:
    spec:
      template:
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: Exists
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOC
kubectl get tigerastatus -w                     # calico, apiserver가 Available이 될 때까지
kubectl get ippool -o custom-columns='NAME:.metadata.name,VXLAN:.spec.vxlanMode'   # Always
kubectl get nodes                               # CP 3대 Ready
```

## 5. Mac: CP timer 설치를 다시 실행

Terraform apply 때 SSM이 timer 설치를 이미 한 번 실행했지만, 그때는 kubeadm 클러스터가 없어서 "Control Plane이 아니라 건너뜁니다"로 끝났습니다. init이 끝났으니 다시 실행합니다.

```bash
ID=$(AWS_PROFILE=mulo-login aws ssm list-associations --region ap-northeast-2 \
  --association-filter-list key=AssociationName,value=mulo-v3-prod-control-plane-timers \
  --query 'Associations[0].AssociationId' --output text)
AWS_PROFILE=mulo-login aws ssm start-associations-once --region ap-northeast-2 --association-ids "$ID"
```

CP에서 확인:

```bash
systemctl list-timers 'mulo-*' --no-pager
sudo journalctl -u mulo-worker-token.service -n 3 --no-pager   # "가입 정보 게시 완료"
```

이제 SSM에 가입 토큰이 있으니, 먼저 떠서 기다리던 워커 4대가 가입합니다. 워커 User Data는 토큰을 최대 1시간 기다립니다. 그보다 오래 걸렸다면 해당 워커 EC2를 종료해 ASG가 새로 띄우게 합니다.

```bash
kubectl get nodes -L workload -w
```

## 6. 그다음

Helm 저장소(16-mulo-kube)의 런북 순서대로 foundation → Argo CD → EBS CSI → Vault(KMS auto-unseal로 바로 init) → root Application을 올립니다.
