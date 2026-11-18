data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# 東京では g6.xlarge を提供していないAZがあるので、提供AZだけにサブネットを作る。
data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.gpu_instance_type]
  }
}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  azs           = sort(data.aws_ec2_instance_type_offerings.gpu.locations)
  function_name = "${var.name_prefix}-function"
}
