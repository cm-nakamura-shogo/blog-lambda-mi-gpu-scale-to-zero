# AWS 公式の Lambda Python 3.12 ベースイメージをダイジェストで固定する(Terraform の var.base_image で上書きする)。
ARG BASE_IMAGE=public.ecr.aws/lambda/python:3.12@sha256:a53086fc3118c5457097083ba3d1ccf1d8fdfcba9e7a90fbfc5d2b06c625215b
FROM ${BASE_IMAGE}

# Triton と FlashInfer が実行時にカーネルを JIT コンパイルするため、C コンパイラーを入れる。
RUN dnf install -y gcc gcc-c++ && dnf clean all

COPY requirements.txt ${LAMBDA_TASK_ROOT}/

# ハッシュ付きロックから、ロック外のパッケージを入れずにホイールだけでインストールする。
RUN pip install --no-cache-dir --require-hashes --no-deps --only-binary=:all: \
      --index-url https://pypi.org/simple \
      -r ${LAMBDA_TASK_ROOT}/requirements.txt

# Lambda では /tmp 以外に書き込めないので、各種キャッシュを /tmp に向ける。
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    HF_HOME=/tmp/.cache/huggingface \
    VLLM_CACHE_ROOT=/tmp/.cache/vllm \
    TRITON_CACHE_DIR=/tmp/.cache/triton \
    FLASHINFER_WORKSPACE_BASE=/tmp/.cache \
    VLLM_USE_FLASHINFER_SAMPLER=0 \
    VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
