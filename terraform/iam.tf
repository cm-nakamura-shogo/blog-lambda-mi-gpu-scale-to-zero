### キャパシティプロバイダーがEC2を管理するためのオペレーターロール

data "aws_iam_policy_document" "operator_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${var.name_prefix}-operator-role"
  assume_role_policy = data.aws_iam_policy_document.operator_trust.json
}

resource "aws_iam_role_policy_attachment" "operator" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSLambdaManagedEC2ResourceOperator"
}

### GPU関数の実行ロール(ログ出力とモデルの読み取り)

data "aws_iam_policy_document" "function_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "function" {
  name               = "${var.name_prefix}-function-role"
  assume_role_policy = data.aws_iam_policy_document.function_trust.json
}

data "aws_iam_policy_document" "function" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.function.arn}:*"]
  }
  # vLLM(Run:ai Model Streamer)が S3 から重みと設定ファイルを読む。
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.model.arn}/${local.model_prefix}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.model.arn]
  }
}

resource "aws_iam_role_policy" "function" {
  name   = "${var.name_prefix}-function-policy"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

### CodeBuildのサービスロール

data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name_prefix}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.codebuild.arn}:*"]
  }
  statement {
    sid       = "ReadSource"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.source.arn}/source-*.zip"]
  }
  statement {
    sid       = "SourceBucketIdentity"
    actions   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.source.arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.this.arn]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.name_prefix}-codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}
