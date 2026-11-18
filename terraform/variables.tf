variable "aws_region" {
  description = "検証するリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "使うAWS CLIのプロファイル"
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "lmi-gpu-s2z"
}

variable "vpc_cidr" {
  description = "検証用VPCのCIDR"
  type        = string
  default     = "10.31.0.0/16"
}

variable "gpu_instance_type" {
  description = "キャパシティプロバイダーで許可するGPUインスタンスタイプ"
  type        = string
  default     = "g6e.xlarge"
}

variable "max_vcpu_count" {
  description = "キャパシティプロバイダー全体のvCPU上限(12未満は拒否される)"
  type        = number
  default     = 12
}

variable "base_image" {
  description = "AWS公式のLambda Pythonベースイメージ(ダイジェストで固定)"
  type        = string
  default     = "public.ecr.aws/lambda/python:3.12@sha256:a53086fc3118c5457097083ba3d1ccf1d8fdfcba9e7a90fbfc5d2b06c625215b"
}

variable "deploy_function" {
  description = "GPU関数を作るかどうか(作るとGPUインスタンスが起動する)"
  type        = bool
  default     = false
}

variable "accelerator_memory_size" {
  description = "GPU 1基あたりの最小メモリ(GiB)。3, 6, 12, 16, 24, 48のいずれか"
  type        = number
  default     = 48
}

variable "function_memory_size" {
  description = "関数のメモリ(MB)。g6e.xlarge(4 vCPU / 32 GiB)で、OS予約を除いた3 vCPU x 8 GiB"
  type        = number
  default     = 24576
}

variable "min_execution_environments" {
  description = "最小実行環境数。0でスケールトゥゼロ"
  type        = number
  default     = 0
}

variable "max_execution_environments" {
  description = "最大実行環境数"
  type        = number
  default     = 1
}

variable "tags" {
  description = "全リソースに付ける共通タグ"
  type        = map(string)
  default = {
    Project   = "lmi-gpu-scale-to-zero"
    ManagedBy = "terraform"
  }
}

variable "model_id" {
  description = "Hugging Face のモデルID"
  type        = string
  default     = "Qwen/Qwen3-30B-A3B-Instruct-2507-FP8"
}

variable "model_revision" {
  description = "モデルのリビジョン(コミットハッシュで固定)"
  type        = string
  default     = "5a5a776300a41aaa681dd7ff0106608ef2bc90db"
}

variable "cuda_graph" {
  description = "Decode 用の CUDA Graph を使うかどうか(false なら Eager)"
  type        = bool
  default     = true
}

variable "load_format" {
  description = "vLLM の重みの読み込み方式(runai_streamer で S3 から直接読む)"
  type        = string
  default     = "runai_streamer"
}
