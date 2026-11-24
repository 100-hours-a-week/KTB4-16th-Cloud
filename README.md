# MULO Terraform

AWS 인프라 설정.

## 디렉터리

- `environments/dev`: 단일 EC2 개발 환경
- `environments/staging`: 스테이징 환경
- `environments/prod`: 운영 환경
- `modules/platform`: 운영·스테이징 공용 모듈

## 실행

Terraform 1.10 이상과 배포 대상 계정의 AWS 인증 정보가 필요합니다.
환경별 디렉터리에서 `terraform.tfvars`를 준비합니다. 운영 환경의 상태는 로컬 `terraform.tfstate`에 저장합니다.
`dev`와 `staging`은 각 디렉터리의 `.example` 파일을 참고합니다.

운영 환경:

```sh
cd environments/prod
terraform init
terraform plan
terraform apply
```

Kubernetes 설치와 애플리케이션 배포는 별도로 진행합니다.

워커 초기 구성은 [워커 가입·라벨·테인트 순서](docs/worker-autojoin/README.md)를 따릅니다. 워커 역할과 배치 조건을 먼저 확인한 뒤 기존 Helm 차트를 사용합니다.

`certificate_arn`은 현재 `null`이며 웹 요청은 HTTP 80으로 받습니다. `request_certificate = true`면 Terraform이 `mulostudio.p-e.kr`과 `*.mulostudio.p-e.kr` ACM 인증서를 DNS 검증으로 요청합니다. Route 53 존이 위임돼야 발급되며, `terraform output certificate`의 status가 `ISSUED`가 되면 그 arn을 `certificate_arn`에 넣고 다시 apply합니다. 그러면 HTTPS 443과 HTTP→HTTPS 리다이렉트가 켜집니다.

## 이번에 정한 기본 동작

- **Calico는 VXLAN Always**입니다. 보안 그룹은 노드 사이 UDP 4789만 열고, source/destination check는 기본값(켜짐)을 유지합니다. 클러스터 쪽 전환은 [6.0절](docs/worker-autojoin/README.md#60-cp1에서-calico를-vxlan-always로-바꾼다)을 봅니다.
- **운영 도구 도메인은 허용 IP만** 들어옵니다. `admin_allowed_cidrs`에 팀원 IP를 넣어야 plan이 통과합니다. 나머지 요청은 ALB가 403을 돌려줍니다.
- **WAF**: IP 하나당 5분에 `waf_rate_limit`(기본 2000)번이 넘으면 막습니다. 공통 규칙 중 8KB 넘는 본문을 막는 `SizeRestrictions_BODY`는 이미지 업로드 때문에 count로 바꿨습니다.
- **system 노드 역할**: EBS CSI에 더해 Loki 버킷 S3 권한(`loki_use_node_role`)과 Vault KMS auto-unseal 권한(`vault_kms_use_node_role`)을 줍니다. OIDC로 Pod 전용 IAM을 만들면 이 값을 끕니다.
- **S3 정리**: Loki 버킷은 이전 버전만 7일 뒤 지우고, etcd·Vault 백업은 `backup_retention_days`(기본 30일)가 지나면 지웁니다. images 버킷은 건드리지 않습니다.

## Argo CD·PLG 접속 도메인

`environments/prod/terraform.tfvars`의 기존 `config` 안에 운영 도구를 등록합니다. 아래 주소는 현재 앱 도메인인 `mulostudio.p-e.kr` 기준이며 `hostname`을 원하는 주소로 바꿀 수 있습니다. 이 파일은 Git에서 제외되므로 다른 배포 환경에서는 직접 설정합니다.

```hcl
  platform_services = {
    argocd = {
      hostname     = "argocd.mulostudio.p-e.kr"
      namespace    = "argocd"
      service_name = "argocd-server"
      service_port = 80
    }
    grafana = {
      hostname     = "grafana.mulostudio.p-e.kr"
      namespace    = "monitoring"
      service_name = "grafana"
      service_port = 80
    }
    prometheus = {
      hostname     = "prometheus.mulostudio.p-e.kr"
      namespace    = "monitoring"
      service_name = "prometheus-kube-prometheus-prometheus"
      service_port = 9090
    }
  }
```

위 설정은 Argo CD·Grafana와 Prometheus 조회 화면을 연결합니다. Prometheus는 `prometheus.mulostudio.p-e.kr`에서 직접 메트릭을 조회할 수 있습니다. Grafana의 기존 Loki·Prometheus 데이터소스는 클러스터 내부 Service 주소를 계속 사용합니다. Loki API도 직접 노출해야 한다면 같은 맵에 `monitoring/loki:3100`을 추가할 수 있습니다. Promtail·Alloy 로그 수집기는 별도 접속 사이트가 필요하지 않습니다.

운영 도구 규칙은 호스트 이름과 함께 `admin_allowed_cidrs`의 출발지 IP 조건을 겁니다. 서비스마다 ALB 호스트 규칙을 생성하므로 앱용 `public_hosts`의 1~3개 제한과 무관하게 추가할 수 있습니다. 등록하지 않은 호스트는 기존처럼 403을 반환합니다. 도메인은 서로 달라야 하며 `public_hosts`와 중복될 수 없습니다. 설정을 생략하면 운영 도구용 리소스를 생성하지 않습니다.

요청 경로는 `도메인 → ALB → Envoy NodePort → HTTPRoute → ClusterIP Service`입니다. Terraform은 ALB 규칙과 DNS 레코드를 관리하고, 클러스터 연결 없이 HTTPRoute YAML을 출력합니다. Kubernetes·Helm 배포는 아래 단계에서 진행합니다.

### 1. AWS 규칙과 DNS

```sh
cd environments/prod
terraform plan -out=platform.tfplan
# 계획의 전체 변경 내용을 확인한 후 적용합니다.
terraform apply platform.tfplan
terraform output platform_access
terraform output -raw platform_http_routes > /tmp/mulo-platform-routes.yaml
```

`route53_zone`을 지정했다면 이 모듈이 관리하는 공개 존에 ALB Alias A 레코드를 생성합니다. 해당 존의 NS가 실제 도메인에 위임되어 있어야 DNS 조회에 반영됩니다. NS는 `terraform output migration`의 `route53_zone.name_servers`에서 확인합니다. 외부 DNS를 계속 사용한다면 사용 중인 DNS에 각 서브도메인의 CNAME을 `platform_access`의 `dns_target`으로 등록합니다. `route53_zone = null`인 구성에서는 Route 53 레코드를 만들지 않습니다. [Alias 레코드 설정](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record#alias-record)

HTTPS를 사용하려면 `certificate_arn`의 ACM 인증서가 운영 도구 도메인까지 포함해야 합니다. 예를 들어 `*.mulostudio.p-e.kr`은 위 세 서브도메인을 포함합니다. 인증서가 없으면 출력 URL은 `http://`, 지정하면 `https://`입니다.

### 2. Argo CD·Grafana·Prometheus의 외부 URL

아래 명령은 계속 `environments/prod`에서 실행합니다. Helm·kubectl·jq와 대상 클러스터 접근 권한이 필요합니다. `GITOPS_DIR`은 기존 Helm values가 있는 `mulo` 저장소 경로로 지정합니다. 기존 설정 위에 외부 URL만 덮어씁니다.

```sh
GITOPS_DIR=../../../mulo
ARGOCD_URL="$(terraform output -json platform_access | jq -er '.argocd.url')"
GRAFANA_URL="$(terraform output -json platform_access | jq -er '.grafana.url')"
GRAFANA_HOST="$(terraform output -json platform_access | jq -er '.grafana.hostname')"
PROMETHEUS_URL="$(terraform output -json platform_access | jq -er '.prometheus.url')"

helm upgrade --install argocd argo/argo-cd --version 10.17.2 \
  --namespace argocd --create-namespace \
  -f "$GITOPS_DIR/system/argocd/values.yaml" \
  --set-string "configs.cm.url=$ARGOCD_URL" \
  --set 'configs.params.server\.insecure=true' --wait

helm upgrade --install grafana grafana/grafana --version 10.5.15 \
  --namespace monitoring --create-namespace \
  -f "$GITOPS_DIR/system/monitoring/grafana/values.yaml" \
  --set-string "grafana\.ini.server.domain=$GRAFANA_HOST" \
  --set-string "grafana\.ini.server.root_url=$GRAFANA_URL/" --wait

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 93.2.0 \
  --namespace monitoring --create-namespace \
  -f "$GITOPS_DIR/system/monitoring/prometheus/values.yaml" \
  --set-string "prometheus.prometheusSpec.externalUrl=$PROMETHEUS_URL" \
  --set-string 'prometheus.prometheusSpec.routePrefix=/' --wait
```

Envoy는 Argo CD의 HTTP 포트 80으로 전달하므로 `server.insecure=true`가 필요합니다. 이를 설정하지 않으면 Argo CD가 자체 HTTPS로 리다이렉트할 수 있습니다. 외부 HTTPS는 ALB에서 종료합니다. Argo CD CLI는 이 HTTP 라우트를 통해 접속할 때 `--grpc-web`을 사용합니다. [Argo CD Gateway API 설정](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#gateway-api-example)

위 Helm 변경은 GitOps로 관리하는 원본 values에도 반영해야 이후 동기화에서 유지됩니다. 인증서를 추가해 URL이 HTTPS로 바뀌면 같은 명령으로 외부 URL을 갱신합니다.

### 3. Envoy 라우트

기존 `mulo` Gateway의 기본값은 `edge/mulo-gateway`, listener `http`입니다. 다르면 `config` 안에서 다음 값을 변경한 뒤 Terraform 계획·적용 및 YAML 출력을 다시 진행합니다.

```hcl
  platform_gateway = {
    name          = "mulo-gateway"
    namespace     = "edge"
    listener_name = "http"
  }
```

Gateway가 선택하는 namespace 라벨을 추가하고 생성된 YAML을 검토·적용합니다. 아래 라벨은 기존 `mulo` Gateway의 `allowedRouteNamespaceLabels` 기준입니다. foundation 차트의 해당 namespace 라벨에도 같은 값을 반영합니다. Gateway·Envoy controller·대상 Service가 먼저 설치되어 있어야 합니다. [Gateway의 namespace 선택](https://gateway-api.sigs.k8s.io/guides/user-guides/multiple-ns/)

```sh
kubectl label namespace argocd monitoring mulo.io/gateway-access=true --overwrite
cat /tmp/mulo-platform-routes.yaml
kubectl apply -f /tmp/mulo-platform-routes.yaml
kubectl -n argocd get httproute argocd-external -o yaml
kubectl -n monitoring get httproute grafana-external -o yaml
kubectl -n monitoring get httproute prometheus-external -o yaml
```

각 HTTPRoute의 `Accepted`, `ResolvedRefs`가 `True`이고 ALB 대상이 정상인지 확인한 뒤 `platform_access`의 URL로 접속합니다. 기존 네트워크 정책에서도 `edge`에서 대상 서비스 포트로의 통신을 허용해야 합니다. DNS 전파 전에는 `curl -H 'Host: argocd.mulostudio.p-e.kr' http://<ALB-DNS>`로 HTTP 구성을 확인할 수 있습니다.

## 검증

AWS 리소스를 만들지 않는 mock 테스트입니다.

```sh
terraform fmt -check -recursive
terraform -chdir=modules/platform validate
terraform -chdir=environments/prod validate
terraform -chdir=modules/platform test
```
