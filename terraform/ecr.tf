resource "aws_ecr_repository" "this" {
  name                 = local.function_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the latest 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# この関数(バージョン付きARNを含む)にだけイメージの取得を許可する。
data "aws_iam_policy_document" "ecr_lambda_pull" {
  statement {
    sid     = "LambdaECRImageRetrievalPolicy"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${local.account_id}:function:${local.function_name}",
        "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${local.account_id}:function:${local.function_name}:*",
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.ecr_lambda_pull.json
}
