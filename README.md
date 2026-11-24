# MULO v2 Terraform

MULO의 개발·스테이징·운영 인프라를 Google Cloud에 정의하던 저장소입니다. 서비스가 다른 환경으로 마이그레이션되어 **GCP 리소스는 모두 삭제했고, Terraform 코드와 state에서도 제거했습니다.**

남은 것은 각 환경의 state 위치와 provider 설정, 그리고 Terraform CI가 쓰는 리소스(WIF 풀 `github-pool`, 서비스 계정 `terraform-plan`·`terraform-apply`, state 버킷 `mulo-v2-tfstate-953840519216`)입니다. 자세한 내용은 [환경 공통 구성](environments/README.md)을 참고하세요.

이전 구성의 변경 내용과 검증 기록은 [작업·검증·인수인계 기록](docs/작업-검증-인수인계.md)과 git 기록에 남아 있습니다.

## 저장소 구조

```text
environments/
  dev/       개발 환경 state 위치와 provider 설정
  staging/   스테이징 환경 state 위치와 provider 설정
  prod/      운영 환경 state 위치와 provider 설정
```

각 환경의 `backend.tf`는 공통 GCS 버킷의 `dev`·`staging`·`prod` 경로로 state를 분리합니다. 버킷과 팀원 연결은 [팀 공유 state 안내](environments/STATE.md)를 참고합니다.

전체 `terraform destroy`는 쓰지 않습니다. 남은 CI용 리소스는 Terraform이 관리하지 않으며, 지우면 CI가 깨집니다.
