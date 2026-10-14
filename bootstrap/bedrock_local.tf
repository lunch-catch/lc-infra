/*
 * 백엔드 담당자가 로컬에서 Bedrock 을 직접 불러 볼 IAM 사용자다 (docs/system-design/런치캐치_LLM_Bedrock.md 6절).
 * 로컬에는 서버 역할이 없어 키가 필요하다. 개발 서버에 병합해 확인하는 것보다 빠르게 프롬프트를 고치려는 용도다.
 *
 * 그 모델 하나의 호출만 허용한다. 콘솔 로그인, 다른 서비스, 다른 모델은 모두 막힌다.
 * 키가 새도 할 수 있는 일은 그 모델 호출뿐이고 한 건이 0.001 USD 수준이다.
 *
 * 액세스 키는 Terraform 이 만들지 않는다. 만들면 비밀 키가 상태 파일에 평문으로 남는다.
 * 사람이 aws iam create-access-key 로 발급하고, 다 쓰면 끄거나 지운다.
 * 사람마다 사용자를 따로 둔다. 키를 돌려쓰면 누가 썼는지와 언제 끌지가 흐려진다.
 */

variable "bedrock_local_users" {
  description = "로컬 Bedrock 호출용 IAM 사용자를 만들 GitHub 아이디"
  type        = list(string)
  default     = ["yongmaru789"]
}

# terraform/ 의 bedrock_model_id 와 같은 값이어야 한다. 루트가 달라 변수를 공유하지 못한다.
variable "bedrock_local_model_id" {
  description = "로컬에서 허용할 Bedrock 모델 ID"
  type        = string
  default     = "openai.gpt-oss-120b-1:0"
}

resource "aws_iam_user" "bedrock_local" {
  for_each = toset(var.bedrock_local_users)
  name     = "${var.project}-bedrock-local-${each.key}"

  tags = {
    Purpose = "local Bedrock invoke only"
    Owner   = each.key
  }
}

data "aws_iam_policy_document" "bedrock_local" {
  statement {
    sid     = "InvokeTemplateModel"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:::foundation-model/${var.bedrock_local_model_id}",
      "arn:aws:bedrock:*::foundation-model/${var.bedrock_local_model_id}",
    ]
  }
}

resource "aws_iam_user_policy" "bedrock_local" {
  for_each = aws_iam_user.bedrock_local
  name     = "bedrock-invoke"
  user     = each.value.name
  policy   = data.aws_iam_policy_document.bedrock_local.json
}

output "bedrock_local_users" {
  description = "키를 발급할 IAM 사용자 이름"
  value       = { for k, u in aws_iam_user.bedrock_local : k => u.name }
}
