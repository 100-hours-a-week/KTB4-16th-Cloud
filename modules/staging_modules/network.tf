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

# 루트 모듈은 전용 VPC를 사용하며, default VPC 조회는 선택 옵션입니다.
resource "google_compute_network" "main" {
  count                   = var.use_default_vpc ? 0 : 1
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required]
}

# VM 주소를 할당하는 서브넷입니다. 공인 IP 없이 Google API에 접근할 수 있게 합니다.
resource "google_compute_subnetwork" "app" {
  count                    = var.use_default_vpc ? 0 : 1
  name                     = "${var.name_prefix}-app"
  region                   = var.region
  network                  = google_compute_network.main[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Cloud NAT는 VM의 외부 다운로드·API 호출을 위한 경로이며 외부에서 VM으로 접속하는 입구는 아닙니다.
resource "google_compute_router" "nat" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = local.network_id
}

resource "google_compute_router_nat" "app" {
  name                   = "${var.name_prefix}-nat"
  router                 = google_compute_router.nat.name
  region                 = var.region
  nat_ip_allocate_option = "AUTO_ONLY"
  # 이 환경의 VM 서브넷에만 NAT를 적용합니다.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = local.subnetwork_id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Cloud SQL 같은 관리형 서비스가 사용할 사설 주소 범위입니다. VM 서브넷과는 별도입니다.
resource "google_compute_global_address" "sql_peering" {
  name          = "${var.name_prefix}-sql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = local.network_id
  depends_on    = [google_project_service.required]
}

# 예약한 범위로 Private Services Access를 연결한 뒤 Cloud SQL의 사설 IP를 생성합니다.
resource "google_service_networking_connection" "sql" {
  network                 = local.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_peering.name]
  depends_on              = [google_project_service.required]
}



# Google의 LB 프록시·헬스체크 주소에서 앱 포트로 들어오는 요청만 허용합니다.
# 방화벽 대상은 네트워크 태그이며, 서비스 탐색에 사용하는 VM 라벨과는 별개입니다.
resource "google_compute_firewall" "load_balancer" {
  name          = "${var.name_prefix}-allow-lb"
  network       = local.network_name
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name_prefix}-app"]

  allow {
    protocol = "tcp"
    ports    = [for port in distinct(values(var.service_ports)) : tostring(port)]
  }
}
# IAP의 TCP 전달 주소에서 SSH를 허용합니다. 실제 접속에는 별도의 IAP·OS Login 권한이 필요합니다.
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

# 모니터링 VM에서 앱의 서비스 포트로 지표를 수집합니다. 지표 경로는 앱에서 구성합니다.
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

# 앱 VM에서 모니터링 VM의 Loki로 로그를 전송합니다. 로그 수집기는 직접 설치합니다.
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
