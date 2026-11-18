output "availability_zones" {
  value = local.azs
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "capacity_provider_arn" {
  value = aws_lambda_capacity_provider.gpu.arn
}

output "image_uri" {
  value = "${aws_ecr_repository.this.repository_url}@${data.aws_ecr_image.function.image_digest}"
}

output "function_name" {
  value = var.deploy_function ? local.function_name : null
}

output "model_uri" {
  value = local.model_uri
}
