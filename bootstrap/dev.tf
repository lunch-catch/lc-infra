/*
 * 개발 서버가 기대는 것 중 파괴를 견뎌야 하는 둘이다 (INF-45, docs/system-design/런치캐치_개발서버.md).
 *
 * 개발 서버 자체는 dev/ 가 갖고 필요할 때만 올린다. 그런데 develop 병합은 서버가 내려가 있을 때도
 * 일어난다. 그때도 이미지는 쌓이고 배포 역할은 있어야 다음에 올릴 때 최신으로 뜬다.
 */

# 개발 이미지다. 운영 ECR 은 terraform/ 에 있어 운영 destroy 때 사라지므로 따로 둔다.
resource "aws_ecr_repository" "dev" {
  name = "${var.project}-dev"

  # 태그가 커밋 SHA 라 덮어쓸 일이 없다. 운영과 같은 이유로 막는다.
  image_tag_mutability = "IMMUTABLE"

  # 개발 이미지는 커밋으로 언제든 다시 만든다. 지울 때 비어 있지 않다고 막히지 않게 한다.
  force_delete = true
}

# develop 병합마다 쌓이니 오래된 것을 지운다. 개발 서버가 되돌아갈 일은 드물다.
resource "aws_ecr_lifecycle_policy" "dev" {
  repository = aws_ecr_repository.dev.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

/*
 * 개발 배포 역할의 권한이다. 운영 리소스는 하나도 건드리지 못한다.
 *
 *   개발 ECR push
 *   SSM /<project>/dev/current-sha 쓰기
 *   Role=dev-server 태그가 붙은 인스턴스에만 Run Command
 */
data "aws_iam_policy_document" "deploy_dev" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # DescribeImages 는 재실행 때 이미 올린 SHA 를 건너뛰는 데 쓴다. 저장소가 IMMUTABLE 이라 다시 밀면 거부된다.
  statement {
    sid    = "PushDevImage"
    effect = "Allow"

    actions = [
      "ecr:DescribeImages",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]

    resources = [aws_ecr_repository.dev.arn]
  }

  statement {
    sid       = "UpdateDevSha"
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/dev/current-sha"]
  }

  # 개발 서버가 떠 있는지 본다. 내려가 있으면 워크플로가 재시작을 건너뛴다.
  statement {
    sid       = "FindDevServer"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "RestartDevServer"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["dev-server"]
    }
  }

  statement {
    sid       = "RunShellScriptDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_dev" {
  name   = "deploy-dev"
  role   = aws_iam_role.github["deploy-dev"].id
  policy = data.aws_iam_policy_document.deploy_dev.json
}

output "dev_ecr_url" {
  description = "개발 이미지 저장소. lc-backend 의 deploy-dev.yml 이 push 한다"
  value       = aws_ecr_repository.dev.repository_url
}
