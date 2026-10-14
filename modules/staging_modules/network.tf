# 옵션으로 기존 default VPC와 해당 리전의 default 서브넷을 사용할 수 있습니다.
data "google_compute_network" "default" {
  count      = var.use_default_vpc ? 1 : 0
  name       = "default"
  project    = var.project_id
  depends_on = [google_project_service.required]
}

data "google_compute_subnetwork" "default" {
  count      = var.use_default_vpc ? 1 : 0
  name       = "default"
  region     = var.region
  project    = var.project_id
  depends_on = [google_project_service.required]
}

locals {
  network_id    = var.use_default_vpc ? data.google_compute_network.default[0].id : google_compute_network.main[0].id
  network_name  = var.use_default_vpc ? data.google_compute_network.default[0].name : google_compute_network.main[0].name
  subnetwork_id = var.use_default_vpc ? data.google_compute_subnetwork.default[0].id : google_compute_subnetwork.app[0].id
}

// 스테이징 환경에서는 전용 VPC를 생성합니다.
resource "google_compute_network" "main" {
  count                   = var.use_default_vpc ? 0 : 1
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required]
}

// Compute Engine이 들어갈 서브넷 정의
resource "google_compute_subnetwork" "app" {
  count                    = var.use_default_vpc ? 0 : 1
  name                     = "${var.name_prefix}-app"
  region                   = var.region
  network                  = google_compute_network.main[0].id // VPC에 속하게 된다.
  ip_cidr_range            = var.subnet_cidr                   // cidr 설정 해야함
  private_ip_google_access = true                              // GCP API에 접근할 수 있게 한다.
}

// Public IP가 없는 VM의 OS 업데이트 및 외부 AI API 호출을 위한 NAT Gateway(Cloud NAT)
resource "google_compute_router" "nat" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = local.network_id // VPC 연결
}

resource "google_compute_router_nat" "app" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.nat.name // Cloud Router에 NAT 설정 연결
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"           // NAT에 사용할 외부 IP 자동 할당 설정
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS" // 모든 서브넷이 아니라, 아래 subnetwork 블록에 지정한 서브넷에만 NAT 적용

  subnetwork {
    name                    = local.subnetwork_id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"] // 해당 서브넷이나 네트워크 내의 모든 Private 주소가 외부 인터넷과 통신할때 NAT Gateway를 거치게 한다.
  }
}

# Cloud SQL private IP용 peering 설정
resource "google_compute_global_address" "sql_peering" {
  name          = "${var.name_prefix}-sql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = local.network_id
  depends_on    = [google_project_service.required]
}

// 추가 설명 필요
resource "google_service_networking_connection" "sql" {
  network                 = local.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_peering.name]
  depends_on              = [google_project_service.required]
}



// Google Frontends와 헬스체크가 서비스 포트로만 접근할 수 있게 하는 방화벽 설정
resource "google_compute_firewall" "load_balancer" {
  name          = "${var.name_prefix}-allow-lb"
  network       = local.network_name
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"] // 로드밸런서 프록시와 상태 검사가 VM에 접속할때 사용하는 구글 IP 대역
  target_tags   = ["${var.name_prefix}-app"]          // 네트워크 태그에 mulo-v2-app인 경우 적용한다. label 아님

  allow {
    protocol = "tcp"
    ports    = [for port in distinct(values(var.service_ports)) : tostring(port)]
  }
}
// 1. values(var.service_ports): 서비스 포트 값들을 꺼냅니다.
// 2. distinct(..): 같은 번호가 두 번 있으면 중복 제거합니다.
// 3. tostring(port): 각 번호를 방화벽 설정용 문자열로 바꿉니다.

// IAP 권한이 있는 사람만 VM에 SSH 접속할 수 있게하는 firewall 설정
resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = local.network_name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-app", "${var.name_prefix}-monitoring", "${var.name_prefix}-redis"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# 모니터링 VM에서 앱 VM의 서비스 포트로 내부 접근을 허용합니다.
resource "google_compute_firewall" "monitoring_scrape" {
  name        = "${var.name_prefix}-allow-monitoring-scrape"
  network     = local.network_name
  direction   = "INGRESS"
  source_tags = ["${var.name_prefix}-monitoring"]
  target_tags = ["${var.name_prefix}-app"]

  allow {
    protocol = "tcp"
    ports    = [for port in distinct(values(var.service_ports)) : tostring(port)]
  }
}

# 모니터링 VM의 Prometheus가 앱 VM의 Node Exporter를 수집합니다.
resource "google_compute_firewall" "monitoring_node_exporter" {
  name        = "${var.name_prefix}-allow-node-exporter"
  network     = local.network_name
  direction   = "INGRESS"
  source_tags = ["${var.name_prefix}-monitoring"]
  target_tags = ["${var.name_prefix}-app"]

  allow {
    protocol = "tcp"
    ports    = ["9100"]
  }
}

# 앱 VM의 로그 수집기가 모니터링 VM의 Loki로 로그를 전송합니다.
resource "google_compute_firewall" "monitoring_loki_ingest" {
  name        = "${var.name_prefix}-allow-loki-ingest"
  network     = local.network_name
  direction   = "INGRESS"
  source_tags = ["${var.name_prefix}-app"]
  target_tags = ["${var.name_prefix}-monitoring"]

  allow {
    protocol = "tcp"
    ports    = ["3100"]
  }
}
