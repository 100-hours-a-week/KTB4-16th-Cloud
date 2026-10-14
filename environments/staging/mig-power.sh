#!/bin/bash
# Terraform 출력의 스테이징 MIG만 대상으로 실행합니다. 모니터링/Redis/Cloud SQL은 runtime_enabled로 관리합니다.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$script_dir" "$@" <<'PY'
import json
import subprocess
import sys
import time

if len(sys.argv) != 3 or sys.argv[2] not in {"status", "stop", "start"}:
    sys.exit("사용법: ./mig-power.sh status|stop|start")

directory, action = sys.argv[1:]

def run(args, capture=False):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None, timeout=600)

def list_instances(base, group, scope):
    return json.loads(run(base + ["list-instances", group, "--format=json"] + scope, True).stdout)

def wait_for_power(base, group, scope, names, action, deadline):
    # 전원 상태만 기다립니다. 수동 앱 설치로 남는 VERIFYING 상태는 시작 완료로 취급합니다.
    previous = None
    next_report = 0
    while True:
        rows = {vm["instance"].rsplit("/", 1)[-1]: vm for vm in list_instances(base, group, scope)}
        missing = set(names) - rows.keys()
        if missing:
            raise ValueError(f"{group}: 대상 VM이 그룹에서 사라졌습니다: {', '.join(sorted(missing))}")
        pending = []
        for name in names:
            vm = rows[name]
            status = vm.get("instanceStatus", "UNKNOWN")
            operation = vm.get("currentAction", "NONE")
            ready = status in {"TERMINATED", "STOPPED"} if action == "stop" else status == "RUNNING" and operation in {"NONE", "VERIFYING"}
            if not ready:
                pending.append(f"{name}: {status} ({operation})")
        if not pending:
            print(f"{group}: {action} 완료", flush=True)
            return
        message = ", ".join(pending)
        now = time.monotonic()
        if message != previous or now >= next_report:
            print(f"{group}: 전원 변경 대기 (제한까지 {max(0, int(deadline - now))}초) — {message}", flush=True)
            previous = message
            next_report = now + 30
        if now >= deadline:
            raise ValueError(f"{group}: 10분 안에 전원 변경이 완료되지 않았습니다: {message}")
        time.sleep(5)

try:
    # 현재 Terraform 상태의 출력값을 사용해 다른 환경이나 독립 VM을 대상으로 삼지 않습니다.
    config = json.loads(run(["terraform", f"-chdir={directory}", "output", "-json", "mig_control"], True).stdout)
    scope = [f"--project={config['project_id']}", f"--zone={config['zone']}"]
    groups = config["mig_names"]
    if set(groups) != {"frontend", "backend", "ai", "chat"}:
        sys.exit("예상한 스테이징 앱 MIG 4개가 아닙니다. Terraform 적용 결과를 확인하세요.")
    pending_groups = []
    for service, group in sorted(groups.items()):
        base = ["gcloud", "compute", "instance-groups", "managed"]
        rows = list_instances(base, group, scope)
        names = []
        targets = []
        for vm in rows:
            name = vm["instance"].rsplit("/", 1)[-1]
            status = vm.get("instanceStatus", "UNKNOWN")
            operation = vm.get("currentAction", "NONE")
            print(f"{service}\t{name}\t{status}\t{operation}", flush=True)
            if status == "UNKNOWN":
                sys.exit("VM 상태를 확인하지 못했습니다. 전원 변경을 중단합니다.")
            if action == "status":
                continue
            # VERIFYING은 앱 헬스체크 대기이므로 전원 변경을 막지 않습니다.
            allowed = {"NONE", "VERIFYING", "STOPPING" if action == "stop" else "STARTING"}
            if operation not in allowed:
                raise ValueError(f"{group}: {name}에서 {operation} 작업이 진행 중입니다. 완료 후 재시도하세요.")
            targets.append(name)
            if (action == "stop" and status == "RUNNING") or (action == "start" and status in {"TERMINATED", "STOPPED"}):
                if operation not in {"STOPPING", "STARTING"}:
                    names.append(name)
        if action != "status" and names:
            run(base + [f"{action}-instances", group, "--instances=" + ",".join(names), "--quiet"] + scope)
        if action != "status" and targets:
            pending_groups.append((group, targets))
    # 모든 그룹에 먼저 요청해 LB 연결 드레이닝이 동시에 진행되게 합니다.
    if pending_groups:
        if action == "stop":
            print("중지 요청 전송 완료. LB 연결 드레이닝 설정에 따라 실제 중지까지 몇 분 걸릴 수 있습니다.", flush=True)
        deadline = time.monotonic() + 600
        # 대기 제한은 그룹마다 초기화하지 않고 전체 그룹이 같은 종료 시각을 공유합니다.
        for group, targets in pending_groups:
            wait_for_power(base, group, scope, targets, action, deadline)
except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
    sys.exit(f"MIG {action} 실패: {exc}. 상태를 확인한 뒤 같은 명령으로 재시도하세요.")
PY
