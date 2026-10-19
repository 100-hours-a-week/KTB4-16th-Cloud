# MULO v2 Terraform

MULO의 개발·스테이징·운영 인프라를 Google Cloud에 정의합니다. 기본 리전은 서울(`asia-northeast3`), VM 배치 존은 `asia-northeast3-a`입니다.

2026-10-14부터 진행한 변경 내용, 검증 결과, 장애 이력과 다음 작업은 [작업·검증·인수인계 기록](docs/작업-검증-인수인계.md)에 정리했습니다. MIG·LB 질문 답변과 실행 위치별 확인 명령도 포함합니다.

운영 검증 이후 진행할 수집 자동화·대시보드·알림·장애 재현은 [모니터링 구축·검증 실행 계획](docs/모니터링-구축-실행계획.md)을 따릅니다. Compose 없이 앱이 자동 실행되는 원리도 설명합니다.

## 환경 한눈에 보기

| 환경 | 앱 배치 | 데이터베이스 | 외부 요청 진입점 |
| --- | --- | --- | --- |
| [개발](environments/dev/README.md) | VM 1대에서 서비스 4개 실행 | 개발용 MySQL 1대·PostgreSQL 1대 | VM의 Nginx |
| [스테이징](environments/staging/README.md) | MIG 4개에 앱 VM 5대 | 스테이징 전용 MySQL 2대·PostgreSQL 1대 | HTTPS 로드 밸런서 |
| [운영](environments/prod/README.md) | MIG 4개에 앱 VM 5대 | 기존 backend·AI DB 재사용, chat DB 생성 | HTTPS 로드 밸런서 |

스테이징과 운영에는 Redis VM과 모니터링 VM도 각각 1대씩 있습니다. 두 VM은 독립 VM이며 고정 내부 IP를 사용합니다.

## 이번 앱 자동 부팅을 처음 적용할 때

[앱 부팅 전환 안내의 최초 적용](environments/BOOTSTRAP.md#2-최초-적용)을 staging부터 순서대로 진행합니다.

1. 실행 계정 권한을 확인하고 시크릿·권한·DNS를 먼저 적용합니다.
2. 서비스별 실제 env를 등록합니다.
3. 최초 연결용 MIG 설정으로 새 부팅 템플릿을 적용하고 앱·LB 상태를 확인합니다.
4. MIG의 version 무시와 일반 롤링 정책을 복구합니다.

시크릿 등록 전에 전체 `terraform apply`를 실행하면 새 VM이 env를 읽지 못할 수 있습니다. staging에서 정상 부팅을 확인한 뒤 prod에도 같은 순서로 적용합니다. 환경별 README의 일반 중지·시작 절차는 최초 전환을 마친 뒤 사용합니다.

## 저장소 구조

```text
environments/
  dev/              개발 환경의 입력값과 모듈 연결
  staging/          스테이징 환경의 입력값과 모듈 연결
  prod/             운영 환경의 입력값과 모듈 연결
modules/
  dev_modules/      개발 리소스 정의
  staging_modules/  스테이징 리소스 정의
  prod_modules/     운영 리소스 정의
enable-pgvector.sql  AI DB의 vector 확장 SQL
```

각 `environments/<환경>/main.tf`가 같은 환경의 `modules/<환경>_modules`를 호출합니다. Terraform 명령은 해당 환경 폴더에서 실행하고, 실제 입력값은 그 폴더의 `terraform.tfvars`에 둡니다.

각 환경의 `backend.tf`는 공통 GCS 버킷의 `dev`·`staging`·`prod` 경로로 state를 분리합니다. 버킷 준비와 기존 로컬 state 이전, 팀원 연결은 [팀 공유 state 안내](environments/STATE.md)를 먼저 진행합니다.

## 관리 범위

Terraform은 VM·네트워크·방화벽·Cloud SQL·이미지 버킷과 서비스 계정을 관리합니다. 스테이징·운영에는 외부·내부 로드 밸런서, 사설 DNS, 인스턴스 템플릿, MIG, Cloud Tasks 큐, 앱 env 시크릿과 읽기 권한도 포함됩니다.

개발 환경은 기존 SSH 배포 방식을 사용합니다. 스테이징·운영의 앱 `bootstrap.sh`는 Docker 등 기본 도구를 설치하고, 매 부팅마다 템플릿의 이미지와 Secret Manager의 env로 앱을 실행합니다. Redis·모니터링은 기존 기반 설치 스크립트를 유지하며 서비스와 Compose 파일은 직접 구성합니다. DB 사용자·비밀번호, 시크릿 값, CD 인증 권한은 직접 준비합니다.

앱 MIG의 템플릿은 VM 생성 설정이며, VM 안에서 직접 작성한 파일을 저장하지 않습니다. 앱 자동 복구·내부 주소·RATE 설정은 [공통 MIG 설명](environments/README.md#앱-mig의-동작), 실제 최초 적용 순서는 [앱 부팅 전환 안내](environments/BOOTSTRAP.md)를 참고하세요.

`tfplan*`·`*.tfplan`은 일회성 실행 계획이고 `.DS_Store`는 macOS 임시 파일이므로 커밋에서 제외합니다. `terraform.tfstate`는 실제 리소스를 추적하는 상태 파일이므로 삭제하지 않습니다. `.terraform.lock.hcl`은 공급자 버전을 고정하는 파일로 커밋에 포함합니다.

환경 비교와 서비스 간 연결은 [공통 구성](environments/README.md), 각 환경의 VM·DB 사양은 위 환경별 문서에서 확인할 수 있습니다. 요구 버전은 Terraform **1.6 이상**, Google provider **7.x**입니다.
