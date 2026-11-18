### モデルの重みを置くS3バケットと、Hugging Face から転送する CodeBuild

locals {
  model_prefix = "models/${replace(lower(var.model_id), "/", "--")}/${var.model_revision}"
  model_uri    = "s3://${aws_s3_bucket.model.id}/${local.model_prefix}"
}

resource "aws_s3_bucket" "model" {
  bucket        = "${var.name_prefix}-model-${local.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "model" {
  bucket                  = aws_s3_bucket.model.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudwatch_log_group" "model_sync" {
  name              = "/aws/codebuild/${var.name_prefix}-model-sync"
  retention_in_days = 7
}

resource "aws_iam_role" "model_sync" {
  name               = "${var.name_prefix}-model-sync-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json
}

data "aws_iam_policy_document" "model_sync" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.model_sync.arn}:*"]
  }
  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.model.arn}/models/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.model.arn]
  }
}

resource "aws_iam_role_policy" "model_sync" {
  name   = "${var.name_prefix}-model-sync-policy"
  role   = aws_iam_role.model_sync.id
  policy = data.aws_iam_policy_document.model_sync.json
}

resource "aws_codebuild_project" "model_sync" {
  name          = "${var.name_prefix}-model-sync"
  service_role  = aws_iam_role.model_sync.arn
  build_timeout = 60

  source {
    type      = "NO_SOURCE"
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          on-failure: ABORT
          commands:
            - pip install --quiet "huggingface_hub[hf_xet]==2.3.0"
            - hf download "$MODEL_ID" --revision "$MODEL_REVISION" --local-dir /tmp/model --exclude "*.md" --exclude ".gitattributes"
            - rm -rf /tmp/model/.cache
            - aws s3 sync /tmp/model "s3://$MODEL_BUCKET/$MODEL_PREFIX/" --only-show-errors
            - aws s3 ls --summarize --human-readable "s3://$MODEL_BUCKET/$MODEL_PREFIX/"
    YAML
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

    environment_variable {
      name  = "MODEL_ID"
      value = var.model_id
    }
    environment_variable {
      name  = "MODEL_REVISION"
      value = var.model_revision
    }
    environment_variable {
      name  = "MODEL_BUCKET"
      value = aws_s3_bucket.model.id
    }
    environment_variable {
      name  = "MODEL_PREFIX"
      value = local.model_prefix
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.model_sync.name
    }
  }

  depends_on = [aws_iam_role_policy.model_sync]
}

action "aws_codebuild_start_build" "model_sync" {
  config {
    project_name = aws_codebuild_project.model_sync.name
    timeout      = 3600
  }
}

# モデルIDかリビジョンが変わったときだけ転送する。
resource "terraform_data" "model_sync" {
  input = local.model_prefix

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.model_sync]
    }
  }

  depends_on = [aws_codebuild_project.model_sync]
}
