#!/bin/bash
set -euo pipefail

# Default values
REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
PUBLIC_CERT_ARN=""
HOSTED_ZONE_ID=""
PRIVATE_CA_ARN=""
DOMAIN_NAME=""

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
    --public-cert-arn)
      PUBLIC_CERT_ARN="$2"
      shift 2
      ;;
    --hosted-zone-id)
      HOSTED_ZONE_ID="$2"
      shift 2
      ;;
    --private-ca-arn)
      PRIVATE_CA_ARN="$2"
      shift 2
      ;;
    --domain-name)
      DOMAIN_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Determine certificate type based on parameters
if [[ -n "$PUBLIC_CERT_ARN" ]]; then
  CERT_TYPE="public"
else
  CERT_TYPE="private"
fi

echo "=== Deploying Load Balancer with TLS ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Certificate Type: $CERT_TYPE"

export AWS_REGION=$REGION

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=ClusterIP

echo "Waiting for NGINX ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# Create demo-app namespace
echo "Creating demo-app namespace..."
kubectl create namespace demo-app --dry-run=client -o yaml | kubectl apply -f -

# Deploy demo application
echo "Deploying demo application..."
kubectl apply -f "$(dirname "$0")/manifests/demo-app.yaml"

# Deploy non-TLS ingress for the demo app (TLS will terminate at NLB)
echo "Deploying non-TLS ingress for demo app..."
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
  
  if [[ -z "$PRIVATE_CA_ARN" ]]; then
    echo "Error: --private-ca-arn is required for private certificates"
    exit 1
  fi
  
  echo "Using Private CA: $PRIVATE_CA_ARN"
  
  # Determine domain name for private certificate
  if [[ -n "$DOMAIN_NAME" ]]; then
    CERT_DOMAIN_NAME="$DOMAIN_NAME"
  else
    CERT_DOMAIN_NAME="*.elb.${REGION}.amazonaws.com"
  fi
  
  # Request certificate from Private CA
  CERT_ARN=$(aws acm request-certificate \
    --domain-name "$CERT_DOMAIN_NAME" \
    --certificate-authority-arn $PRIVATE_CA_ARN \
    --region $REGION \
    --query 'CertificateArn' \
    --output text)
  
  echo "Certificate ARN: $CERT_ARN"
fi

# Deploy Network Load Balancer targeting ingress controller
export CERT_ARN=$CERT_ARN
envsubst < "$(dirname "$0")/manifests/load-balancer.yaml" | kubectl apply -f -

echo "Waiting for load balancer to be ready..."
kubectl wait --for=condition=ready pod --selector=app=demo-app --timeout=180s -n demo-app

# Get NLB hostname
NLB_HOSTNAME=""
for i in {1..30}; do
  NLB_HOSTNAME=$(kubectl get service demo-nlb -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -n "$NLB_HOSTNAME" ]]; then
    break
  fi
  echo "Waiting for NLB to be provisioned... ($i/30)"
  sleep 10
done

if [[ -z "$NLB_HOSTNAME" ]]; then
  echo "Warning: NLB hostname not available yet. Check status with:"
  echo "kubectl get service demo-nlb -n ingress-nginx"
else
  echo "NLB provisioned: $NLB_HOSTNAME"
  
  # DNS setup for certificates
  CERT_DOMAIN=""
  if [[ "$CERT_TYPE" == "public" ]]; then
    # For public certificates, always use the domain from the certificate
    CERT_DOMAIN=$(aws acm describe-certificate \
      --certificate-arn $PUBLIC_CERT_ARN \
      --region $REGION \
      --query 'Certificate.DomainName' \
      --output text)
  elif [[ -n "$DOMAIN_NAME" ]]; then
    # For private certificates, use the provided domain name
    CERT_DOMAIN="$DOMAIN_NAME"
  fi
  
  if [[ -n "$CERT_DOMAIN" && -n "$HOSTED_ZONE_ID" ]]; then
    echo "Creating DNS record..."
    aws route53 change-resource-record-sets \
      --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch "{
        \"Changes\": [{
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"$CERT_DOMAIN\",
            \"Type\": \"CNAME\",
            \"TTL\": 300,
            \"ResourceRecords\": [{\"Value\": \"$NLB_HOSTNAME\"}]
          }
        }]
      }"
    echo "DNS record created: $CERT_DOMAIN -> $NLB_HOSTNAME"
  elif [[ "$CERT_TYPE" == "public" ]]; then
    CERT_DOMAIN=$(aws acm describe-certificate \
      --certificate-arn $PUBLIC_CERT_ARN \
      --region $REGION \
      --query 'Certificate.DomainName' \
      --output text)
    
    echo ""
    echo "=== DNS Setup Required ==="
    echo "For the public certificate to work, create a DNS record:"
    echo "Domain: $CERT_DOMAIN"
    echo "Type: CNAME"
    echo "Value: $NLB_HOSTNAME"
    echo ""
  fi
  
  # Wait for NLB to be ready to accept traffic
  echo "Waiting for NLB to be ready to accept traffic..."
  for i in {1..20}; do
    if curl -k -s --connect-timeout 5 "https://$NLB_HOSTNAME/healthz" >/dev/null 2>&1; then
      echo "NLB is ready to accept traffic!"
      break
    fi
    echo "Waiting for NLB readiness... ($i/20)"
    sleep 15
  done
  
  echo "=== Deployment Complete ==="
  echo "Your load balancer is now available at:"
  echo "https://${NLB_HOSTNAME}"
  echo ""
  if [[ "$CERT_TYPE" == "private" ]]; then
    echo "Note: Since the certificate is issued by a private CA, your browser will show a warning."
    echo "To trust the certificate, you need to import the CA certificate into your trust store."
  fi
fi
