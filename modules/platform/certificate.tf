# 앱 도메인도 운영 도구와 같이 ALB를 가리키게 합니다. DNS 위임(p-e.kr에 NS 등록)은 별도 단계입니다.
resource "aws_route53_record" "public" {
  for_each = var.config.route53_zone == null ? toset([]) : toset(var.config.public_hosts)
  zone_id  = aws_route53_zone.public[0].zone_id
  name     = each.value
  type     = "A"

  alias {
    name                   = aws_lb.web.dns_name
    zone_id                = aws_lb.web.zone_id
    evaluate_target_health = true
  }
}

# 메일(MX)·SPF(TXT)처럼 ALB와 무관한 레코드입니다. 기존 DNS에서 Route 53으로 옮길 때 빠뜨리면 메일이 끊깁니다.
resource "aws_route53_record" "extra" {
  for_each = var.config.route53_zone == null ? {} : var.config.route53_extra_records
  zone_id  = aws_route53_zone.public[0].zone_id
  name     = each.value.name
  type     = each.value.type
  ttl      = each.value.ttl
  records  = each.value.records
}

# ALB에서 TLS를 끝낼 ACM 인증서입니다. 존 이름과 그 아래 한 단계 서브도메인(api, argocd 등)을 모두 덮습니다.
# 검증 레코드만 만들고 발급 완료를 기다리지 않습니다. DNS 위임이 끝나야 실제로 발급됩니다.
# 발급(ISSUED)을 확인한 뒤 출력된 ARN을 config.certificate_arn에 넣으면 HTTPS 리스너가 생깁니다.
resource "aws_acm_certificate" "web" {
  count                     = var.config.request_certificate ? 1 : 0
  domain_name               = trimsuffix(var.config.route53_zone, ".")
  subject_alternative_names = ["*.${trimsuffix(var.config.route53_zone, ".")}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# 존 이름과 와일드카드는 같은 검증 레코드를 쓰므로 덮어쓰기를 허용합니다.
# 검증 값은 발급 요청 뒤에야 알 수 있어서, 키는 미리 아는 도메인 이름으로 고정합니다.
locals {
  certificate_domains = var.config.request_certificate ? toset([
    trimsuffix(var.config.route53_zone, "."),
    "*.${trimsuffix(var.config.route53_zone, ".")}",
  ]) : toset([])
}

resource "aws_route53_record" "certificate_validation" {
  for_each        = local.certificate_domains
  zone_id         = aws_route53_zone.public[0].zone_id
  name            = one([for o in aws_acm_certificate.web[0].domain_validation_options : o.resource_record_name if o.domain_name == each.key])
  type            = one([for o in aws_acm_certificate.web[0].domain_validation_options : o.resource_record_type if o.domain_name == each.key])
  ttl             = 300
  records         = [one([for o in aws_acm_certificate.web[0].domain_validation_options : o.resource_record_value if o.domain_name == each.key])]
  allow_overwrite = true
}
