/*
 * 백엔드 팀원이 개발 서버의 로그와 DB 를 직접 보는 IAM 사용자다 (docs/system-design/런치캐치_개발서버.md 10장).
 *
 * 허용하는 것은 셋뿐이다.
 *   개발 서버 MySQL 로의 SSM 포트 포워딩 (셸 접속은 안 된다)
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

  # 자기가 연 세션만 닫고 이어 붙인다
  statement {
    sid       = "OwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"]
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

  # 계정 단위 호출이라 그룹을 좁히지 못한다. 목록만 보이고 내용은 위 문장이 정한다
  statement {
    sid       = "ListLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTeamDbPassword"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/dev/team-db-password"]
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
