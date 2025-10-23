#!/bin/bash
set -euo pipefail

# Default values
REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
CERT_TYPE=${CERT_TYPE:-private}

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

echo "=== Deploying TLS-enabled Ingress ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Certificate Type: $CERT_TYPE"

export AWS_REGION=$REGION

echo "Installing NGINX Ingress Controller..."
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace ingress-nginx \
  --create-service-account \
  --service-account-name ingress-nginx \
  --permission-policy-arns arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy 2>&1 | grep -v "already exists" || true

sleep 15

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=ingress-nginx \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing"

echo "Waiting for the load balancer to be provisioned..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

LOAD_BALANCER_HOSTNAME=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load balancer hostname: $LOAD_BALANCER_HOSTNAME"

# Handle certificate provisioning based on type
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Setting up public certificate from ACM..."
  
  # Request public certificate
  CERT_ARN=$(aws acm request-certificate \
    --domain-name "$LOAD_BALANCER_HOSTNAME" \
    --validation-method DNS \
    --region $REGION \
    --query 'CertificateArn' \
    --output text)
  
  echo "Certificate ARN: $CERT_ARN"
  echo "Waiting for certificate validation..."
  aws acm wait certificate-validated --certificate-arn $CERT_ARN --region $REGION
  
  # Export certificate for Kubernetes secret
  echo "Exporting certificate for Kubernetes..."
  aws acm export-certificate \
    --certificate-arn $CERT_ARN \
    --region $REGION \
    --query 'Certificate' \
    --output text > /tmp/cert.pem
  
  aws acm export-certificate \
    --certificate-arn $CERT_ARN \
    --region $REGION \
    --query 'PrivateKey' \
    --output text > /tmp/key.pem
  
  # Create Kubernetes secret
  kubectl create secret tls demo-app-tls \
    --cert=/tmp/cert.pem \
    --key=/tmp/key.pem \
    --namespace demo-app \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Clean up temporary files
  rm -f /tmp/cert.pem /tmp/key.pem
  
else
  echo "Using private certificate from AWS Private CA..."
fi

echo "Deploying a demo application..."
export LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME

if [[ "$CERT_TYPE" == "public" ]]; then
  envsubst < "$(dirname "$0")/manifests/demo-app-public.yaml" | kubectl apply -f -
else
  envsubst < "$(dirname "$0")/manifests/demo-app-private.yaml" | kubectl apply -f -
fi

echo "=== Deployment Complete ==="
echo "Your TLS-enabled ingress is now available at:"
echo "https://${LOAD_BALANCER_HOSTNAME}"
echo ""
if [[ "$CERT_TYPE" == "private" ]]; then
  echo "Note: Since the certificate is issued by a private CA, your browser will show a warning."
  echo "To trust the certificate, you need to import the CA certificate into your trust store."
else
  echo "The certificate is issued by a public CA and should be trusted by browsers."
fi