# blog-lambda-mi-gpu-scale-to-zero

Lambda Managed Instances の GPU 関数(g6e.xlarge、NVIDIA L40S)で vLLM と Qwen3-30B-A3B-Instruct-2507-FP8 を動かし、スケールトゥゼロからの復帰時間を測った検証コードです。

Terraform の構成は [Lamaglama39/lambda-managed-instances-gpu](https://github.com/Lamaglama39/lambda-managed-instances-gpu) を参考にしています。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `app/` | GPU関数のコンテナイメージ(vLLM で LLM を初期化中にロードし、ハンドラーで生成する) |
| `terraform/` | VPC、ECR、CodeBuild(イメージのビルドとモデルの転送)、S3、Capacity Provider、GPU関数 |
| `scripts/` | 計測スクリプト |
| `results/` | 計測結果 |

GPU関数は、AWS Provider(6.73.0)の `aws_lambda_function` が `AcceleratorConfig` に未対応のため、`aws_cloudformation_stack` で作っています。

## 前提

- Terraform 1.14 以上(Terraform actions を使うため)
- 東京リージョンの「Running On-Demand G and VT instances」クォータ(g6e.xlarge は 4 vCPU)
- uv(計測スクリプトの実行用)

## 手順

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init

# 1. VPC、ECR、S3、Capacity Provider を作り、イメージのビルドとモデルの転送を行う(GPUインスタンスはまだ起動しない)
terraform apply

# 2. GPU関数を作る(GPUインスタンスが起動し、初期化が終わると ACTIVE になる)
terraform apply -var deploy_function=true

# 3. ゼロまで縮んだ後に、復帰時間を測る
cd ../scripts
uv run cold_start.py --profile <プロファイル> --function lmi-gpu-s2z-function --vpc-id "$(terraform -chdir=../terraform output -raw vpc_id)" --out ../results/cold1

# 4. 温まった状態の速度を測る
uv run bench.py --profile <プロファイル> --function lmi-gpu-s2z-function --inputs 254 --concurrency 1,4 --out ../results/bench_cudagraph.json

# 5. 最後の呼び出しからインスタンスが終了するまでを監視する
uv run watch_scale_down.py --profile <プロファイル> --vpc-id "$(terraform -chdir=../terraform output -raw vpc_id)" --interval 15 --out ../results/scale_down.jsonl

# 6. (任意)イメージの展開後のサイズを測る。IMAGE_TAG は ECR のタグ
aws codebuild start-build --project-name lmi-gpu-s2z-image-build \
  --buildspec-override file://../scripts/inspect-image-buildspec.yml \
  --environment-variables-override name=IMAGE_TAG,value=<タグ>

# 7. 片付け
cd ../terraform
terraform destroy -var deploy_function=true
```

## 依存パッケージのロック

`app/requirements.txt` は `app/pyproject.toml` から uv で生成したハッシュ付きのロックです。
`llguidance` の x86_64 ホイールは `manylinux_2_31` 以上向けなので、Amazon Linux 2023(glibc 2.34)に合わせて `manylinux_2_34` を指定しています。

```bash
cd app
uv pip compile pyproject.toml --generate-hashes \
  --python-version 3.12 --python-platform x86_64-manylinux_2_34 \
  --only-binary :all: --exclude-newer "7 days" \
  --no-header --no-annotate -o requirements.txt
```

## 費用の目安(東京リージョン)

- 手順1の後: NAT ゲートウェイ、S3(約29GiB)、ECR(約4.8GB)
- GPUインスタンスが動いている間: g6e.xlarge $2.699/時 + 管理手数料15% = 約$3.10/時
