# terraform init -backend-config=backend.hcl
# 운영(terraform/)과 같은 버킷에 키만 다르다. 둘을 따로 올리고 내린다.
bucket = "tfstate-lunchcatch"
key    = "dev/terraform.tfstate"
region = "ap-northeast-2"
