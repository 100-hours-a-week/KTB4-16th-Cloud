# etcd 전용 볼륨으로 옮기기

Terraform은 CP마다 20GiB gp3 볼륨을 만들어 `/dev/sdf`로 붙이기만 합니다. etcd 데이터를 옮기는 건 아래 순서로 직접 합니다.

**한 번에 CP 한 대씩** 합니다. etcd는 3대 중 2대가 살아 있어야 동작하므로, 한 대가 끝나서 다시 healthy가 된 걸 확인한 뒤 다음 대로 넘어갑니다.

## 0. 시작 전 확인 (CP1)

```bash
# 3개 멤버가 모두 started이고 healthy인지 확인
kubectl -n kube-system get pods -l component=etcd -o wide
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name '^etcd$'
```

먼저 스냅샷을 하나 떠 둡니다. CP timer가 설치돼 있으면 리더에서 바로 실행합니다.

```bash
sudo systemctl start mulo-etcd-snapshot.service
sudo journalctl -u mulo-etcd-snapshot.service -n 5 --no-pager
```

## 1. 옮길 CP에서 실행

```bash
# t3 같은 Nitro 인스턴스에서는 /dev/sdf가 NVMe 이름으로 보입니다. 볼륨 ID로 찾습니다.
lsblk -o NAME,SIZE,SERIAL,MOUNTPOINT
# SERIAL이 vol0123... 처럼 Terraform output이나 콘솔의 etcd 볼륨 ID와 같은 디스크를 고릅니다.
DEV=/dev/nvme1n1   # 위에서 확인한 이름으로 바꿉니다

# 비어 있는 새 볼륨인지 확인합니다. 파일시스템이 이미 있으면 멈추고 확인합니다.
sudo blkid "$DEV" && echo "이미 파일시스템이 있습니다. 멈추세요." || echo "비어 있음"

sudo mkfs.ext4 -L etcd "$DEV"
sudo mkdir -p /mnt/etcd-new
sudo mount "$DEV" /mnt/etcd-new

# etcd static Pod를 내립니다. manifest를 빼면 kubelet이 etcd를 멈춥니다.
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.moving
# etcd 컨테이너가 사라질 때까지 기다립니다.
while sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name '^etcd$' -q | grep -q .; do sleep 2; done

# 데이터를 그대로 복사합니다(권한·시간 유지).
sudo rsync -aHAX /var/lib/etcd/ /mnt/etcd-new/
sudo umount /mnt/etcd-new

# 기존 디렉터리는 지우지 않고 이름만 바꿔 둡니다.
sudo mv /var/lib/etcd /var/lib/etcd.old
sudo mkdir -p /var/lib/etcd && sudo chmod 700 /var/lib/etcd

# 재부팅해도 붙도록 fstab에 UUID로 등록합니다.
UUID="$(sudo blkid -s UUID -o value "$DEV")"
echo "UUID=$UUID /var/lib/etcd ext4 defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount /var/lib/etcd
df -h /var/lib/etcd

# fstab의 nofail은 볼륨이 없어도 OS 부팅은 계속되게 합니다(SSM으로 들어가 복구할 수 있게).
# 대신 kubelet은 볼륨이 마운트돼야만 시작하게 막습니다. 마운트 없이 시작하면 etcd가 빈 디렉터리로 떠서
# 새 클러스터를 만들어 버릴 수 있습니다.
sudo mkdir -p /etc/systemd/system/kubelet.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/etcd\n' | sudo tee /etc/systemd/system/kubelet.service.d/10-mulo-etcd-mount.conf
sudo systemctl daemon-reload
systemctl show kubelet -p Requires | grep -q var-lib-etcd.mount && echo "kubelet이 etcd 마운트를 요구함"

# etcd를 다시 올립니다.
sudo mv /root/etcd.yaml.moving /etc/kubernetes/manifests/etcd.yaml
```

## 2. 확인 (CP1)

```bash
kubectl -n kube-system get pods -l component=etcd -o wide   # 방금 옮긴 노드의 etcd가 Running
kubectl get --raw='/readyz?verbose' | grep etcd             # [+]etcd ok
```

정상이면 다음 CP로 넘어갑니다. 3대 모두 끝나고 하루 이상 문제가 없으면 각 CP의 `/var/lib/etcd.old`를 지웁니다.

## 되돌리기

옮긴 노드의 etcd가 올라오지 않으면 그 노드에서:

```bash
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.moving
sudo umount /var/lib/etcd
sudo sed -i '\|/var/lib/etcd ext4|d' /etc/fstab
sudo rm -f /etc/systemd/system/kubelet.service.d/10-mulo-etcd-mount.conf && sudo systemctl daemon-reload
sudo rmdir /var/lib/etcd && sudo mv /var/lib/etcd.old /var/lib/etcd
sudo mv /root/etcd.yaml.moving /etc/kubernetes/manifests/etcd.yaml
```
