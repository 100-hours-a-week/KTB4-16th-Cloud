# 앱 VM 자동 부팅 적용

staging·prod 앱 VM이 부팅할 때 이미지와 Secret Manager의 env로 앱을 실행하도록 하는 구성입니다. CD 파이프라인은 참고 자료이며 이 저장소에서 배포 도구를 추가하거나 수정하지 않습니다.

## 1. 남겨 둔 스크립트

| 파일 | 하는 일 | 사용 방식 |
| --- | --- | --- |
| 각 환경의 `bootstrap.sh` | Docker 등 도구 설치, 앱·Node Exporter 실행 | 앱 VM 부팅 시 자동 실행 |
| 각 환경의 `base-bootstrap.sh` | Redis·모니터링의 기존 기반 설치 내용 유지 | 독립 VM의 기존 설정 유지 |
| 각 환경의 `shutdown.sh` | 앱에 SIGTERM을 보내고 최대 60초 기다림 | 앱 VM 종료 시 자동 실행 |
| staging의 `mig-power.sh` | 앱 VM 중지·시작·상태 조회 | 필요할 때 직접 실행 |

Terraform이 스크립트를 VM 메타데이터에 넣습니다. 앱 VM에 이 파일들을 직접 복사하거나 실행할 필요는 없습니다. `base-bootstrap.sh`는 기존 스크립트 내용을 그대로 보존합니다. Redis의 시작 스크립트 내용을 바꾸면 VM 교체가 발생할 수 있어 앱 부팅 스크립트와 분리했습니다.

`bootstrap.sh`의 최초 설치는 한 번만 수행하고 앱 실행은 매 부팅마다 수행합니다. 앱은 `app`, Node Exporter는 `node-exporter` 컨테이너입니다. 로그는 `/var/log/mulo-bootstrap.log`, env는 root만 읽고 쓸 수 있는 `/opt/app/app.env`에 저장됩니다. chat은 아직 이미지가 없으므로 기본 도구만 설치합니다.

## 2. 최초 적용

아래는 staging 기준입니다. prod에서는 폴더를 `environments/prod`, 시크릿 접두사를 `mulo-v2`, 내부 DNS의 `staging`을 `prod`로 바꿉니다. 전원 관리 단계는 staging에만 해당합니다.

### 1. 실행 계정 권한과 DB 확인

Terraform 실행 계정에는 시크릿 IAM을 변경하는 `secretmanager.secrets.setIamPolicy` 권한이 필요합니다. 기본 역할은 **Secret Manager Admin (`roles/secretmanager.admin`)**입니다. 프로젝트 관리자에게 Terraform 실행 계정에 부여해 달라고 요청합니다. 앱 VM 계정에는 Terraform이 해당 서비스의 시크릿 읽기 권한을 부여합니다. [GCP 권한 안내](https://docs.cloud.google.com/secret-manager/docs/manage-access-to-secrets)

현재 provider는 로컬 ADC 인증을 사용합니다. 권한을 받은 사용자 계정으로 ADC를 맞출 필요가 있으면 다음 명령으로 로그인합니다. 이미 올바른 계정을 사용한다면 다시 로그인하지 않아도 됩니다. [Terraform 인증 안내](https://docs.cloud.google.com/docs/terraform/authentication)

```bash
gcloud auth application-default login
```

staging이 중지되어 있다면 Cloud SQL 3대를 콘솔에서 시작해 `RUNNABLE`을 확인하고 `terraform.tfvars`의 `runtime_enabled`를 `true`로 바꿉니다.

### 2. 시크릿·권한·DNS 준비

저장소 루트에서 실행합니다.

```bash
cd environments/staging
terraform init
terraform plan \
  -target=module.mulo.google_secret_manager_secret.app_env \
  -target=module.mulo.google_secret_manager_secret_iam_member.vm_env_reader \
  -target=module.mulo.google_project_iam_member.vm_image_reader \
  -target=module.mulo.google_dns_record_set.service_internal \
  -target=module.mulo.google_compute_firewall.app_internal \
  -out=tfplan-bootstrap-prepare
terraform apply tfplan-bootstrap-prepare
terraform output ai_base_url
terraform output backend_internal_url
```

이 단계는 VM 교체 전에 env를 넣을 시크릿과 읽기 권한·주소를 준비합니다. 내부 LB의 실제 전달 기능은 전체 적용 후 동작합니다.

IAM 적용이 403으로 실패하면 실행 계정 권한을 보완하고 이 단계의 plan을 새로 생성해 재시도합니다. 이미 생성된 시크릿·주소·DNS는 유지합니다. 실패 전에 저장한 plan은 재사용하지 않습니다. 기존 Terraform 상태 파일과 생성된 시크릿은 유지한 채 새 plan으로 재시도합니다. `Applied changes may be incomplete`는 일부 리소스만 선택한 `-target` 적용 안내입니다.

### 3. 실제 env 등록

서비스별 env 파일을 저장소 밖에서 준비합니다. 기존 DB 주소·계정·비밀번호·토큰 등 앱이 필요한 설정을 모두 넣습니다. 형식은 `KEY=VALUE`이며 Docker `--env-file`에서는 따옴표가 값에 포함되므로 값에 따옴표를 붙이지 않습니다.

| 환경 | backend env | AI env |
| --- | --- | --- |
| staging | `AI_BASE_URL=http://ai.staging.mulo.internal:8000` | `BACKEND_INTERNAL_URL=http://backend.staging.mulo.internal:8080/` |
| prod | `AI_BASE_URL=http://ai.prod.mulo.internal:8000` | `BACKEND_INTERNAL_URL=http://backend.prod.mulo.internal:8080/` |

실제 주소는 Terraform 출력으로 확인하며 URL 끝의 `/`는 앱의 요구에 맞춥니다. Redis는 `redis_private_ip`·`redis_port` 출력을 사용합니다. frontend의 빌드 시점 설정은 CI 빌드에서 준비하고 런타임 설정만 env에 넣습니다.

아래 `/안전한경로/`를 실제 파일 경로로 바꿉니다.

```bash
gcloud secrets versions add mulo-v2-staging-backend-env \
  --project=project-7b071b48-8637-467a-80d --data-file=/안전한경로/backend.env
gcloud secrets versions add mulo-v2-staging-ai-env \
  --project=project-7b071b48-8637-467a-80d --data-file=/안전한경로/ai.env
gcloud secrets versions add mulo-v2-staging-frontend-env \
  --project=project-7b071b48-8637-467a-80d --data-file=/안전한경로/frontend.env
```

등록 후 임시 env 파일은 삭제합니다. 시크릿 값은 Terraform·Git에 넣지 않습니다. chat은 이미지가 준비되면 env도 등록합니다.

### 4. 최초 한 번 새 템플릿 연결

MIG의 `version`을 무시하면 기존 MIG에 새 부팅 템플릿이 연결되지 않으므로 최초 연결 때만 설정을 잠시 변경합니다. 대상 파일은 `modules/staging_modules/compute.tf` 또는 `modules/prod_modules/compute.tf`의 **`google_compute_instance_group_manager.service` 리소스**입니다.

- staging: `ignore_changes`에서 `version`만 빼고 `[target_size, target_stopped_size]`를 유지합니다.
- prod: 해당 MIG의 `lifecycle { ignore_changes = [version] }` 블록을 잠시 주석 처리합니다.
- 두 환경: 해당 MIG의 `update_policy`에서 아래 두 값을 사용합니다. 다른 항목은 유지합니다.

```hcl
max_surge_fixed       = 0
max_unavailable_fixed = each.key == "ai" ? var.ai_vm_count : 1
```

최초 교체는 중단을 허용하며 기존 앱 VM을 내린 뒤 새 VM을 만듭니다. 추가 VM용 디스크 할당량을 사용하지 않습니다. 평소 롤링 배포 설정은 확인 후 다음 단계에서 복구합니다.

staging Redis·모니터링이 중지되어 있다면 `runtime_enabled = true` 상태에서 먼저 두 VM을 시작합니다. Redis 사양은 `e2-medium`이며 현재 사양이 다르면 전원 변경 외에 머신 타입 변경도 나타납니다. 디스크 교체가 나타나는지는 따로 확인합니다.

```bash
terraform plan \
  -target=module.mulo.google_compute_instance.redis \
  -target=module.mulo.google_compute_instance.monitoring \
  -out=tfplan-bootstrap-runtime
terraform apply tfplan-bootstrap-runtime
./mig-power.sh start
```

이미 실행 중인 staging과 prod는 위 전원 단계 없이 전체 계획을 확인합니다.

```bash
terraform plan -out=tfplan-bootstrap-rollout
terraform apply tfplan-bootstrap-rollout
```

전체 계획에서 MIG의 `version`이 새 템플릿으로 바뀌는지 확인합니다. Redis는 현재 사양에 따라 머신 타입 변경이 나타날 수 있습니다. Redis·모니터링의 교체나 예상하지 않은 DB 변경은 원인을 확인한 뒤 진행합니다. apply 완료 후에도 VM 안의 설치·앱 부팅은 진행 중일 수 있습니다.

### 5. 정상 상태 확인 후 설정 복구

각 앱 VM에서 확인합니다. backend 예시이며 AI는 `8000/health`, frontend는 `3000/`를 사용합니다.

```bash
sudo tail -n 50 /var/log/mulo-bootstrap.log
sudo docker ps
curl -f http://localhost:8080/actuator/health
```

앱 VM 안에서 내부 통신도 확인합니다.

```bash
curl -f http://ai.staging.mulo.internal:8000/health
curl -f http://backend.staging.mulo.internal:8080/actuator/health
```

앱과 외부·내부 LB의 healthy 상태를 확인한 뒤 4번에서 바꾼 MIG 설정을 원래대로 복구합니다.

- staging: `ignore_changes = [version, target_size, target_stopped_size]`
- prod: `ignore_changes = [version]`인 MIG의 lifecycle 블록 복구
- 두 환경: `max_surge_fixed = 1`, `max_unavailable_fixed = 0`

```bash
terraform plan -out=tfplan-bootstrap-finish
terraform apply tfplan-bootstrap-finish
```

이후 `version` 무시는 CD가 연결한 템플릿을 Terraform이 되돌리지 않도록 하는 일반 설정입니다. 별도 전환 명령은 없습니다. staging에서 재부팅·MIG 재생성 후 앱 복구까지 확인한 뒤 prod에도 같은 순서를 적용합니다. chat은 이미지가 준비되기 전까지 앱 정상 상태 확인에서 제외합니다.

## 3. Terraform과 CD가 공유하는 값

Terraform은 `app-image`(태그 없는 경로), `app-env-secret`, `app-port`, 부팅·종료 스크립트를 템플릿에 넣습니다. `service_image_tags`는 최초 태그입니다. 이후 CD가 만든 템플릿의 `app-image-tag`를 부팅 스크립트가 그대로 읽습니다.

현재 MIG 이름은 운영 `mulo-v2-backend-mig`, staging `mulo-v2-staging-backend-mig`이며 존은 `asia-northeast3-a`입니다. 현재 연결 템플릿은 MIG의 `versions`나 `mig_instance_template_urls` 출력으로 확인합니다. `instance_template_names`는 Terraform의 기반 템플릿 이름입니다.

env 변경은 Secret Manager에 새 버전을 등록한 뒤 재배포·재부팅으로 반영합니다. 부팅 스크립트나 VM 사양을 나중에 바꿀 때는 현재 배포 태그를 Terraform 입력에 맞추고, 위처럼 `version` 무시를 잠시 해제해 새 템플릿을 연결합니다. 일반 변경에서는 정상 롤링 정책인 `max_surge_fixed = 1`, `max_unavailable_fixed = 0`을 유지합니다.
