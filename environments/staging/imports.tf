# 콘솔에서 먼저 부여한 backend·AI의 자기 서명 권한을 상태에 등록합니다.
import {
  to = module.mulo.google_service_account_iam_member.backend_self_signer
  id = "projects/${var.project_id}/serviceAccounts/${var.name_prefix}-backend@${var.project_id}.iam.gserviceaccount.com roles/iam.serviceAccountTokenCreator serviceAccount:${var.name_prefix}-backend@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = module.mulo.google_service_account_iam_member.ai_self_signer
  id = "projects/${var.project_id}/serviceAccounts/${var.name_prefix}-ai@${var.project_id}.iam.gserviceaccount.com roles/iam.serviceAccountTokenCreator serviceAccount:${var.name_prefix}-ai@${var.project_id}.iam.gserviceaccount.com"
}
