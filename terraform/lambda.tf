resource "aws_lambda_capacity_provider" "gpu" {
  name = "${var.name_prefix}-capacity-provider"

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.managed_instances.id]
  }

  permissions_config {
    capacity_provider_operator_role_arn = aws_iam_role.operator.arn
  }

  instance_requirements {
    architectures          = ["x86_64"]
    allowed_instance_types = [var.gpu_instance_type]
  }

  capacity_provider_scaling_config {
    scaling_mode   = "Auto"
    max_vcpu_count = var.max_vcpu_count
  }

  depends_on = [
    aws_cloudwatch_log_group.capacity_provider,
    aws_iam_role_policy_attachment.operator,
    aws_route_table_association.private,
  ]
}

resource "aws_cloudwatch_log_group" "capacity_provider" {
  name              = "/aws/lambda/capacity-provider/${var.name_prefix}-capacity-provider"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 7
}

# AWS Provider は AcceleratorConfig に未対応のため、関数だけ CloudFormation で作る。
resource "aws_cloudformation_stack" "function" {
  count = var.deploy_function ? 1 : 0
  name  = local.function_name

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      Function = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName  = local.function_name
          Role          = aws_iam_role.function.arn
          PackageType   = "Image"
          Code          = { ImageUri = "${aws_ecr_repository.this.repository_url}@${data.aws_ecr_image.function.image_digest}" }
          Architectures = ["x86_64"]
          MemorySize    = var.function_memory_size
          Timeout       = 900
          # 初期化のタイムアウトは「130秒と関数のタイムアウトの大きい方」なので、900秒にして LLM のロードを待つ。
          Environment = {
            Variables = {
              MODEL_URI   = local.model_uri
              CUDA_GRAPH  = var.cuda_graph ? "1" : "0"
              LOAD_FORMAT = var.load_format
            }
          }
          CapacityProviderConfig = {
            LambdaManagedInstancesCapacityProviderConfig = {
              CapacityProviderArn                   = aws_lambda_capacity_provider.gpu.arn
              ExecutionEnvironmentMemoryGiBPerVCpu  = 8
              PerExecutionEnvironmentMaxConcurrency = 1
            }
          }
          AcceleratorConfig        = { AcceleratorMemorySize = var.accelerator_memory_size }
          PublishToLatestPublished = true
          FunctionScalingConfig = {
            MinExecutionEnvironments = var.min_execution_environments
            MaxExecutionEnvironments = var.max_execution_environments
          }
          LoggingConfig = {
            LogFormat = "JSON"
            LogGroup  = aws_cloudwatch_log_group.function.name
          }
        }
      }
    }
    Outputs = {
      FunctionArn = { Value = { "Fn::GetAtt" = ["Function", "Arn"] } }
    }
  })

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  depends_on = [aws_iam_role_policy.function, aws_ecr_repository_policy.this, terraform_data.model_sync]
}
