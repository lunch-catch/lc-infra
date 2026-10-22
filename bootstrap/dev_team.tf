/*
 * 백엔드 팀원이 개발 서버의 로그와 DB 를 직접 보는 IAM 사용자다 (docs/system-design/런치캐치_개발서버.md 10장).
 *
 * 허용하는 것은 넷뿐이다.
 *   개발 서버 MySQL 로의 SSM 포트 포워딩 (셸 접속은 안 된다)
 *   템플릿 생성 Bedrock 모델 호출 (서버와 같은 모델 하나)
 *   개발 앱 로그 읽기 (CloudWatch Logs /<project>/dev/app)
 *   팀 DB 계정 비밀번호 읽기 (SSM /<project>/dev/team-db-password)
 * 운영, S3, 다른 비밀값, 서버 셸은 모두 막힌다.
 *
 * 액세스 키는 Terraform 이 만들지 않는다. 비밀 키가 상태 파일에 평문으로 남기 때문이다.
 * aws iam create-access-key 로 발급하고, 팀에서 빠지면 목록에서 지우고 apply 한다.
 */

variable "dev_team_members" {
  description = "개발 서버 로그와 DB 에 접근할 팀원의 GitHub 아이디"
  type        = list(string)
  default     = ["yongmaru789", "muzimzz", "MinhyeokChoi99", "gyudongjeong"]
}

resource "aws_iam_group" "dev_team" {
  name = "${var.project}-dev-team"
}

/*
 * 로컬 백엔드가 부를 Bedrock 모델이다 (런치캐치_LLM_Bedrock.md 5.1절).
 * terraform/ 과 dev/ 의 bedrock_model_id 와 같은 값이어야 한다. 루트가 달라 변수를 공유하지 못한다.
 */
variable "dev_team_bedrock_model_id" {
  description = "팀원이 로컬에서 부를 수 있는 Bedrock 모델 ID 또는 추론 프로필 ID"
  type        = string
  default     = "jp.anthropic.claude-sonnet-4-6"
}

variable "dev_team_bedrock_region" {
  description = "팀원이 Bedrock 을 부르는 리전"
  type        = string
  default     = "ap-northeast-1"
}

locals {
  dev_team_bedrock_base_model = replace(var.dev_team_bedrock_model_id, "/^(global|apac|us|eu|jp|au|ca)\\./", "")
}

data "aws_iam_policy_document" "dev_team" {
  # 스크립트가 개발 서버 인스턴스 ID 를 태그로 찾는다
  statement {
    sid       = "FindDevServer"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # 개발 서버로만, 포트 포워딩 문서로만 세션을 연다. 셸 세션(기본 문서)은 열 수 없다
  statement {
    sid       = "PortForwardToDevServer"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["dev-server"]
    }

    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "PortForwardDocument"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-StartPortForwardingSession"]
  }

  # 자기가 연 세션만 닫고 이어 붙인다. IAM 사용자는 세션 ID 가 사용자 이름으로 시작한다
  statement {
    sid       = "OwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"]
  }

  # 역할로 들어오면 aws:username 이 없다. 세션에 붙는 태그로 자기 세션을 가린다
  statement {
    sid       = "OwnRoleSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/*"]

    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["$${aws:userid}"]
    }
  }

  statement {
    sid    = "ReadDevAppLogs"
    effect = "Allow"
    actions = [
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:DescribeLogStreams",
      "logs:StartLiveTail",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/dev/app",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/dev/app:*",
    ]
  }

  # 콘솔의 Logs Insights 가 쿼리를 이 그룹에만 건다
  statement {
    sid     = "QueryDevAppLogs"
    effect  = "Allow"
    actions = ["logs:StartQuery", "logs:GetLogGroupFields"]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/dev/app",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/dev/app:*",
    ]
  }

  # 계정 단위 호출이라 그룹을 좁히지 못한다. 목록과 쿼리 결과만 보이고 내용은 위 문장들이 정한다
  statement {
    sid    = "ListLogGroups"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:GetQueryResults",
      "logs:StopQuery",
      "logs:DescribeQueries",
      "logs:DescribeQueryDefinitions",
      "logs:GetLogRecord",
    ]
    resources = ["*"]
  }

  /*
   * 로컬 백엔드에서 템플릿 생성을 진짜 모델로 확인한다. 서버와 같은 모델 하나만 연다.
   * 추론 프로필로 부르면 프로필 ARN 과 그것이 가리키는 모델 ARN 이 함께 있어야 한다.
   */
  statement {
    sid     = "InvokeTemplateModel"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = concat(
      local.dev_team_bedrock_base_model == var.dev_team_bedrock_model_id ? [] : [
        "arn:aws:bedrock:${var.dev_team_bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.dev_team_bedrock_model_id}",
      ],
      [
        "arn:aws:bedrock:::foundation-model/${local.dev_team_bedrock_base_model}",
        "arn:aws:bedrock:*::foundation-model/${local.dev_team_bedrock_base_model}",
      ],
    )
  }

  statement {
    sid     = "ReadTeamDbPassword"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/dev/team-db-password",
      # 개발 Grafana 의 팀 공용 보기 계정(team) 비밀번호다 (개발 서버 문서 11장)
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/dev/grafana-team-password",
      # 개발 앱의 기본 계정 비밀번호 넷(superadmin, demo-admin, demo-owner, scenario)이다. 해시(-password-hash)는 끝이 달라 걸리지 않는다
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/dev/account-*-password",
    ]
  }

  statement {
    sid       = "DecryptViaSsm"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_group_policy" "dev_team" {
  name   = "dev-logs-and-db"
  group  = aws_iam_group.dev_team.name
  policy = data.aws_iam_policy_document.dev_team.json
}

resource "aws_iam_user" "dev_team" {
  for_each = toset(var.dev_team_members)
  name     = "${var.project}-dev-${each.key}"

  tags = {
    Purpose = "dev server logs and db"
    Owner   = each.key
  }
}

resource "aws_iam_user_group_membership" "dev_team" {
  for_each = aws_iam_user.dev_team
  user     = each.value.name
  groups   = [aws_iam_group.dev_team.name]
}

output "dev_team_users" {
  description = "키를 발급할 팀원 IAM 사용자 이름"
  value       = { for k, u in aws_iam_user.dev_team : k => u.name }
}

/*
 * Organization 의 팀원이 자기 계정에서 넘어오는 역할이다 (런치캐치_개발서버.md 10장).
 * 권한은 위 IAM 사용자와 같은 정책이다. 키를 나눠 줄 필요가 없고, 자격 증명은 최대 4시간짜리 임시다.
 *
 * 신뢰는 아래 계정 ID 에만 준다. 같은 Organization 이어도 목록에 없는 계정은 넘어오지 못한다.
 * 계정 ID 는 저장소가 PUBLIC 이라 terraform.tfvars(커밋하지 않는다)에만 둔다.
 * 루트 사용자는 역할을 넘어올 수 없다. 팀원은 자기 계정의 IAM 사용자로 넘어온다.
 */
variable "dev_team_accounts" {
  description = "개발 서버 역할로 넘어올 팀원 계정. 키는 알아보기 쉬운 이름, 값은 12자리 계정 ID"
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.dev_team_accounts) : can(regex("^[0-9]{12}$", id))])
    error_message = "계정 ID 는 12자리 숫자다."
  }
}

variable "organization_id" {
  description = "팀원 계정이 속한 Organization. 목록의 계정이 다른 조직으로 옮겨 가면 막는다"
  type        = string
  default     = "o-2e7zqxkzzh"
}

data "aws_iam_policy_document" "dev_team_trust" {
  count = length(var.dev_team_accounts) > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for id in values(var.dev_team_accounts) : "arn:aws:iam::${id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organization_id]
    }
  }
}

resource "aws_iam_role" "dev_team" {
  count = length(var.dev_team_accounts) > 0 ? 1 : 0

  name               = "${var.project}-dev-team"
  assume_role_policy = data.aws_iam_policy_document.dev_team_trust[0].json

  # DB 포트 포워딩을 오래 열어 두는 경우가 있어 기본 1시간보다 길게 둔다
  max_session_duration = 14400

  tags = {
    Purpose = "dev server logs and db"
  }
}

resource "aws_iam_role_policy" "dev_team" {
  count = length(var.dev_team_accounts) > 0 ? 1 : 0

  name   = "dev-logs-and-db"
  role   = aws_iam_role.dev_team[0].id
  policy = data.aws_iam_policy_document.dev_team.json
}

output "dev_team_role_arn" {
  description = "팀원이 ~/.aws/config 의 role_arn 에 넣는 값"
  value       = length(var.dev_team_accounts) > 0 ? aws_iam_role.dev_team[0].arn : ""
}

output "dev_team_switch_role_url" {
  description = "팀원이 콘솔에서 누르는 역할 전환 링크"
  value       = length(var.dev_team_accounts) > 0 ? "https://signin.aws.amazon.com/switchrole?account=${data.aws_caller_identity.current.account_id}&roleName=${aws_iam_role.dev_team[0].name}&displayName=lunchcatch-dev" : ""
}
