#!/bin/bash
# kafka-ui 이미지를 ECR에 push하는 스크립트
# 사용법: AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 ./push-kafka-ui-to-ecr.sh

set -e

AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:?필요: AWS_ACCOUNT_ID}
AWS_REGION=${AWS_REGION:-ap-northeast-2}
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_NAME="kafka-ui"
IMAGE_TAG="latest"

echo "==> ECR 레포 생성 (이미 있으면 무시)"
aws ecr create-repository \
  --repository-name ${REPO_NAME} \
  --region ${AWS_REGION} \
  --image-scanning-configuration scanOnPush=true \
  2>/dev/null || echo "레포가 이미 존재합니다."

echo "==> ECR 로그인"
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${ECR_REGISTRY}

echo "==> provectuslabs/kafka-ui:latest pull"
docker pull provectuslabs/kafka-ui:latest

echo "==> ECR 태깅"
docker tag provectuslabs/kafka-ui:latest ${ECR_REGISTRY}/${REPO_NAME}:${IMAGE_TAG}

echo "==> ECR push"
docker push ${ECR_REGISTRY}/${REPO_NAME}:${IMAGE_TAG}

echo ""
echo "완료! 아래 값을 monitoring EC2의 .env에 설정하세요:"
echo "ECR_REGISTRY=${ECR_REGISTRY}"
echo "KAFKA_PORT=9092"
echo "KAFKA_EXTERNAL_HOST=<main EC2 public IP 또는 도메인>"
