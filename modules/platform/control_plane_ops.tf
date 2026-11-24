# ---------- etcd 전용 EBS ----------
# etcd는 쓰기마다 fsync를 기다려서 디스크 지연에 민감합니다(Cloud Wiki 3.8 etcd 디스크).
# 시스템·이미지·로그와 IOPS를 나눠 쓰지 않도록 CP마다 gp3 볼륨을 따로 붙입니다.
# 붙이기만 하고 etcd 데이터 이동은 docs/etcd-volume/README.md 순서대로 한 대씩 직접 합니다.
resource "aws_ebs_volume" "etcd" {
  for_each          = local.control_planes
  availability_zone = each.value
  type              = "gp3"
  size              = var.config.etcd_volume_gb
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = {
    Name = "${local.name}-cp-${each.key}-etcd", Role = "etcd", (local.cluster_tag) = "owned"
  }

  lifecycle {
    # etcd 데이터가 들어가는 볼륨이라 실수로 지우지 않게 막습니다.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "etcd" {
  for_each    = local.control_planes
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.etcd[each.key].id
  instance_id = aws_instance.control_plane[each.key].id
  # Terraform이 볼륨을 떼야 할 때 마운트된 상태로 강제로 떼지 않습니다.
  force_detach = false
}

# ---------- CP host timer ----------
# etcd 스냅샷(1시간)과 워커 가입 토큰 갱신(6시간)을 CP 호스트의 systemd timer로 설치합니다.
# SSM이 Role=control-plane 태그가 붙은 CP 3대 모두에 설치하고, 스크립트가 바뀌면 다시 설치합니다.
# 스냅샷은 etcd 리더인 CP 하나만 올리고, 토큰은 어느 CP가 올려도 같은 SSM 경로를 덮어씁니다.
locals {
  control_plane_timer_script = templatefile("${path.module}/templates/control-plane-timers.sh.tftpl", {
    region         = var.region
    etcd_bucket    = aws_s3_bucket.storage["etcd-backup"].bucket
    parameter_name = "/${local.name}/join/worker"
    api_endpoint   = "${aws_lb.api.dns_name}:6443"
  })
}

resource "aws_ssm_document" "control_plane_timers" {
  name            = "${local.name}-control-plane-timers"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install etcd snapshot and worker join token timers on kubeadm control planes"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "installTimers"
      inputs = {
        timeoutSeconds = "600"
        # SSM은 명령을 sh(Ubuntu에서는 dash)로 돌립니다. 스크립트는 bash 문법이라
        # base64로 옮긴 뒤 bash로 실행합니다. SSM 파라미터 문법({{ }})과도 섞이지 않습니다.
        runCommand = [
          "set -e",
          "echo '${base64encode(local.control_plane_timer_script)}' | base64 -d > /run/mulo-control-plane-timers.sh",
          "bash /run/mulo-control-plane-timers.sh",
          "rm -f /run/mulo-control-plane-timers.sh",
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "control_plane_timers" {
  name             = aws_ssm_document.control_plane_timers.name
  association_name = "${local.name}-control-plane-timers"
  # 문서 내용이 바뀌면 새 버전으로 다시 실행합니다.
  document_version = aws_ssm_document.control_plane_timers.latest_version
  # 30분마다 다시 실행합니다. 처음 구축 때 apply 시점에는 클러스터가 없어 건너뛰므로,
  # kubeadm init이 끝나면 늦어도 30분 안에 timer가 설치되고 가입 토큰이 올라갑니다(손으로 다시 실행할 필요 없음).
  # 이미 설치된 CP에서는 스크립트가 바로 끝납니다(토큰을 새로 만들지 않음).
  schedule_expression = "rate(30 minutes)"

  targets {
    key    = "tag:Role"
    values = ["control-plane"]
  }

  targets {
    key    = "tag:${local.cluster_tag}"
    values = ["owned"]
  }
}
