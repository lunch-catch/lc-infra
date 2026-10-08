data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# 운영과 같은 이미지다. 앱 컨테이너가 x86 단일 아키텍처로 빌드된다.
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# 개발 이미지 저장소는 bootstrap/ 이 갖는다. 서버가 내려가 있어도 develop 병합마다 이미지가 쌓인다.
data "aws_ecr_repository" "dev" {
  name = "${var.project}-dev"
}

# 호스팅 영역도 bootstrap/ 이 갖는다. 여기서는 레코드만 넣는다.
data "aws_route53_zone" "main" {
  name = var.zone_name
}

locals {
  ssm_prefix = "/${var.project}"
  name       = "${var.project}-dev"
}

/*
 * 운영 VPC 에 넣지 않는다. 운영은 destroy.sh 로 통째로 내리는데 그 위에 있으면 함께 사라진다.
 * 퍼블릭 서브넷 하나에 두고 NAT 를 두지 않는다. NAT 는 월 43 USD 다 (문서 3장).
 */
resource "aws_vpc" "dev" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.name
  }
}

resource "aws_internet_gateway" "dev" {
  vpc_id = aws_vpc.dev.id

  tags = {
    Name = local.name
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.dev.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dev.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dev.id
  }

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

/*
 * 80 과 443 만 연다. Caddy 가 받는다.
 * 80 은 인증서 발급(HTTP-01)과 HTTPS 리다이렉트용이다. 막으면 인증서를 못 받는다.
 * 앱(8080), 액추에이터(8081), MySQL, Valkey 는 열지 않는다. 컨테이너 네트워크 안에서만 오간다.
 * 운영 접근은 SSM Session Manager 다. 22 는 열지 않는다.
 */
resource "aws_security_group" "dev" {
  name        = local.name
  description = "dev server. 80 and 443 to Caddy only"
  vpc_id      = aws_vpc.dev.id

  tags = {
    Name = local.name
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.dev.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Caddy ACME challenge and redirect"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.dev.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Caddy HTTPS"
}

# ECR pull, SSM, 패키지 설치, 카카오 API 호출이 나간다.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.dev.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "all outbound"
}

/*
 * 서버 역할이다. 운영 시크릿은 읽지 못한다 (문서 5장).
 *
 *   /<project>/dev/*         개발 전용 JWT 키, DB 비밀번호, 배포할 SHA
 *   /<project>/kakao-*       운영과 같은 카카오 앱
 */
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dev" {
  name               = "${local.name}-server"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

# SSM Session Manager 와 Run Command 를 받는다. 배포 워크플로가 Run Command 로 재시작을 건다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "dev" {
  statement {
    sid     = "ReadDevAndKakaoParams"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]

    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/dev/*",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/kakao-*",
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

  # 계정 단위 호출이라 저장소를 좁히지 못한다. 실제로 받는 곳은 아래 문장이 정한다.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "PullDevImage"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [data.aws_ecr_repository.dev.arn]
  }
}

resource "aws_iam_role_policy" "dev" {
  name   = "dev-server"
  role   = aws_iam_role.dev.id
  policy = data.aws_iam_policy_document.dev.json
}

resource "aws_iam_instance_profile" "dev" {
  name = "${local.name}-server"
  role = aws_iam_role.dev.name
}

locals {
  registry = split("/", data.aws_ecr_repository.dev.repository_url)[0]

  refresh = templatefile("${path.module}/templates/refresh.sh.tftpl", {
    project  = var.project
    region   = var.region
    registry = local.registry
  })

  compose = templatefile("${path.module}/templates/compose.yaml.tftpl", {
    project             = var.project
    image               = data.aws_ecr_repository.dev.repository_url
    frontend_origins    = join(",", var.frontend_origins)
    kakao_callback_host = trimprefix(var.frontend_origins[0], "https://")
  })

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    common_bootstrap = file("${path.module}/../terraform/templates/common-bootstrap.sh")
    project          = var.project
    api_host         = var.api_host
    refresh          = local.refresh
    compose          = local.compose
    caddyfile        = templatefile("${path.module}/templates/Caddyfile.tftpl", { api_host = var.api_host })
  })
}

resource "aws_instance" "dev" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.dev.id]
  iam_instance_profile   = aws_iam_instance_profile.dev.name
  user_data_base64       = base64encode(local.user_data)

  # MySQL 데이터, Caddy 인증서, 이미지가 여기 쌓인다.
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = local.name
    Role = "dev-server"
  }

  /*
   * AMI 와 user-data 변경을 무시한다. 둘 다 바뀌면 서버를 새로 만들어 MySQL 데이터와
   * Caddy 인증서가 사라진다. 인증서는 같은 이름에 주 5회까지만 받는다 (문서 7장).
   * 템플릿을 고쳐 반영하려면 사람이 판단해서 교체한다.
   *   terraform -chdir=dev apply -replace=aws_instance.dev
   */
  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}

# 중지했다 켜도 주소가 바뀌지 않게 고정 IP 를 둔다. DNS 레코드가 이것을 가리킨다.
resource "aws_eip" "dev" {
  domain   = "vpc"
  instance = aws_instance.dev.id

  tags = {
    Name = local.name
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.api_host
  type    = "A"
  ttl     = 60
  records = [aws_eip.dev.public_ip]
}

output "instance_id" {
  description = "dev-up.sh 와 dev-down.sh 가 켜고 끈다"
  value       = aws_instance.dev.id
}

output "api_url" {
  description = "개발 백엔드 주소"
  value       = "https://${var.api_host}"
}
