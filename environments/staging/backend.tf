# 버킷 준비와 기존 로컬 state 이전 절차는 ../STATE.md를 참고합니다.
terraform {
  backend "gcs" {
    bucket = "mulo-v2-tfstate-953840519216"
    prefix = "staging"
  }
}
