variable "config" {
  # 타입과 입력 검증은 modules/platform/variables.tf 한 곳에서 관리합니다.
  # 여기서 같은 정의를 반복하면 두 파일이 서로 어긋나기 쉽습니다.
  description = "AWS 인프라와 워커 자동 가입 입력. 항목 설명은 modules/platform/variables.tf를 봅니다."
  type        = any
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}


