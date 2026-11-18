### ビルドのソース(app/)を置くS3バケット

resource "aws_s3_bucket" "source" {
  bucket        = "${var.name_prefix}-source-${local.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/../app"
  output_path = "${path.module}/build/source.zip"
}

locals {
  # ソースが変わるたびに新しいタグでビルドする(リポジトリはIMMUTABLE)。
  image_tag = substr(data.archive_file.source.output_sha256, 0, 12)
}

resource "aws_s3_object" "source" {
  bucket = aws_s3_bucket.source.id
  key    = "source-${local.image_tag}.zip"
  source = data.archive_file.source.output_path
  etag   = data.archive_file.source.output_md5
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.name_prefix}-image-build"
  retention_in_days = 7
}

resource "aws_codebuild_project" "image" {
  name          = "${var.name_prefix}-image-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  source {
    type     = "S3"
    location = "${aws_s3_bucket.source.id}/${aws_s3_object.source.key}"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    # x86_64のイメージをエミュレーションなしでビルドする。
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    privileged_mode = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.this.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = local.image_tag
    }
    environment_variable {
      name  = "BASE_IMAGE"
      value = var.base_image
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

action "aws_codebuild_start_build" "image" {
  config {
    project_name = aws_codebuild_project.image.name
    timeout      = 3600
  }
}

# ソースが変わったときだけビルドする。ビルド完了まで後続が待つ。
resource "terraform_data" "image_build" {
  input = local.image_tag

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.image]
    }
  }

  depends_on = [aws_codebuild_project.image]
}

data "aws_ecr_image" "function" {
  repository_name = aws_ecr_repository.this.name
  image_tag       = terraform_data.image_build.output
}
