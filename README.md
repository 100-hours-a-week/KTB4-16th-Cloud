# MULO v2 Terraform

MULO의 개발·스테이징·운영 인프라를 Google Cloud에 정의합니다. 기본 리전은 서울(`asia-northeast3`), VM 배치 존은 `asia-northeast3-a`입니다.

## 환경 한눈에 보기

| 환경 | 앱 배치 | 데이터베이스 | 외부 요청 진입점 |
| --- | --- | --- | --- |
| [개발](environments/dev/README.md) | VM 1대에서 서비스 4개 실행 | 개발용 MySQL 1대·PostgreSQL 1대 | VM의 Nginx |
| [스테이징](environments/staging/README.md) | MIG 4개에 앱 VM 5대 | 스테이징 전용 MySQL 2대·PostgreSQL 1대 | HTTPS 로드 밸런서 |
| [운영](environments/prod/README.md) | MIG 4개에 앱 VM 5대 | 기존 backend·AI DB 재사용, chat DB 생성 | HTTPS 로드 밸런서 |

스테이징과 운영에는 Redis VM과 모니터링 VM도 각각 1대씩 있습니다. 두 VM은 독립 VM이며 고정 내부 IP를 사용합니다.

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

각 `environments/<환경>/main.tf`가 같은 환경의 `modules/<환경>_modules`를 호출합니다. 환경별 입력값과 Terraform 상태는 `environments`의 각 폴더에서 관리합니다.

## 관리 범위

Terraform은 VM·네트워크·방화벽·Cloud SQL·이미지 버킷과 서비스 계정을 관리합니다. 스테이징·운영에는 로드 밸런서, 인스턴스 템플릿, MIG, Cloud Tasks 큐도 포함됩니다.

VM의 `bootstrap.sh`는 Docker·Compose, Google Cloud CLI, Ops Agent와 2GB 스왑을 준비합니다. 앱·Redis·모니터링 서비스의 설치와 Compose 파일, DB 사용자와 앱 연결 정보는 직접 구성합니다.

환경 비교와 서비스 간 연결은 [공통 구성](environments/README.md), 각 환경의 VM·DB 사양은 위 환경별 문서에서 확인할 수 있습니다. 요구 버전은 Terraform **1.6 이상**, Google provider **7.x**입니다.
