#!/bin/bash
set -euo pipefail

# Default values
REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
CERT_TYPE=${CERT_TYPE:-private}
PUBLIC_CERT_ARN=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --cert-type)
      CERT_TYPE="$2"
      shift 2
      ;;
    --public-cert-arn)
      PUBLIC_CERT_ARN="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ "$CERT_TYPE" != "public" && "$CERT_TYPE" != "private" ]]; then
  echo "Error: --cert-type must be either 'public' or 'private'"
  exit 1
fi

if [[ "$CERT_TYPE" == "public" && -z "$PUBLIC_CERT_ARN" ]]; then
  echo "Error: --public-cert-arn is required when --cert-type is 'public'"
  exit 1
fi

echo "=== Deploying Load Balancer with TLS ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Certificate Type: $CERT_TYPE"

export AWS_REGION=$REGION

# Get ingress service hostname
INGRESS_HOSTNAME=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -z "$INGRESS_HOSTNAME" ]]; then
  echo "Error: No ingress controller found. Please deploy ingress first using deploy-ingress/"
  exit 1
fi

echo "Found ingress hostname: $INGRESS_HOSTNAME"

# Deploy non-TLS ingress for the demo app (TLS will terminate at ALB)
echo "Deploying non-TLS ingress for demo app..."
export LOAD_BALANCER_HOSTNAME=$INGRESS_HOSTNAME
envsubst < "$(dirname "$0")/manifests/non-tls-ingress.yaml" | kubectl apply -f -

# Create certificate based on type
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Using existing public certificate: $PUBLIC_CERT_ARN"
  
  # Verify certificate exists and is issued
  CERT_STATUS=$(aws acm describe-certificate \
    --certificate-arn $PUBLIC_CERT_ARN \
    --region $REGION \
    --query 'Certificate.Status' \
    --output text)
  
  if [[ "$CERT_STATUS" != "ISSUED" ]]; then
    echo "Error: Certificate $PUBLIC_CERT_ARN is not in ISSUED status (current: $CERT_STATUS)"
    exit 1
  fi
  
  CERT_ARN=$PUBLIC_CERT_ARN
  
else
  echo "Using private certificate from AWS Private CA..."
  # Get the Private CA ARN from the cluster issuer
  PRIVATE_CA_ARN=$(kubectl get awspcaclusterissuer aws-pca-cluster-issuer -o jsonpath='{.spec.arn}' 2>/dev/null || echo "")
  
  if [[ -z "$PRIVATE_CA_ARN" ]]; then
    echo "Error: No AWS Private CA found. Please deploy core PKI first using deploy-core-pki/"
    exit 1
  fi
  
  echo "Using Private CA: $PRIVATE_CA_ARN"
  
  # Request certificate from Private CA
  CERT_ARN=$(aws acm request-certificate \
    --domain-name "*.elb.amazonaws.com" \
    --certificate-authority-arn $PRIVATE_CA_ARN \
    --region $REGION \
    --query 'CertificateArn' \
    --output text)
  
  echo "Certificate ARN: $CERT_ARN"
fi

# Deploy Application Load Balancer targeting ingress controller
export CERT_ARN=$CERT_ARN
envsubst < "$(dirname "$0")/manifests/load-balancer.yaml" | kubectl apply -f -

echo "Waiting for load balancer to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/alb-controller -n kube-system 2>/dev/null || true

# Get ALB hostname
ALB_HOSTNAME=""
for i in {1..30}; do
  ALB_HOSTNAME=$(kubectl get ingress demo-alb-ingress -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -n "$ALB_HOSTNAME" ]]; then
    break
  fi
  echo "Waiting for ALB to be provisioned... ($i/30)"
  sleep 10
done

if [[ -z "$ALB_HOSTNAME" ]]; then
  echo "Warning: ALB hostname not available yet. Check status with:"
  echo "kubectl get ingress demo-alb-ingress -n demo-app"
else
  echo "=== Deployment Complete ==="
  echo "Your load balancer is now available at:"
  echo "https://${ALB_HOSTNAME}"
  echo ""
  if [[ "$CERT_TYPE" == "private" ]]; then
    echo "Note: Since the certificate is issued by a private CA, your browser will show a warning."
    echo "To trust the certificate, you need to import the CA certificate into your trust store."
  fi
fi
