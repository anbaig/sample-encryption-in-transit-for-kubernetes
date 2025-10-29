#!/bin/bash
set -euo pipefail

# Default values
REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
PUBLIC_CERT_ARN=""
HOSTED_ZONE_ID=""

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
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "=== Deploying TLS-enabled Ingress ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
if [[ -n "$PUBLIC_CERT_ARN" ]]; then
  echo "Certificate Type: public"
else
  echo "Certificate Type: private"
fi

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
if [[ -n "$PUBLIC_CERT_ARN" ]]; then
  echo "Using existing public certificate: $PUBLIC_CERT_ARN"
  
  # Extract domain from certificate
  CERT_DOMAIN=$(aws acm describe-certificate \
    --certificate-arn $PUBLIC_CERT_ARN \
    --region $REGION \
    --query 'Certificate.DomainName' \
    --output text)
  
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
fi

# Create DNS record if hosted zone ID is provided
if [[ -n "$PUBLIC_CERT_ARN" && -n "$HOSTED_ZONE_ID" ]]; then
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
          \"ResourceRecords\": [{\"Value\": \"$LOAD_BALANCER_HOSTNAME\"}]
        }
      }]
    }"
  echo "DNS record created: $CERT_DOMAIN -> $LOAD_BALANCER_HOSTNAME"
fi

# Export certificate if using public certificate
if [[ -n "$PUBLIC_CERT_ARN" ]]; then
  
  # Export certificate with full chain for Kubernetes secret
  echo "Exporting certificate with full chain for Kubernetes..."
  PASSPHRASE="password"
  PASSPHRASE_B64=$(echo -n "$PASSPHRASE" | base64)
  
  # Export certificate and chain
  aws acm export-certificate \
    --certificate-arn $PUBLIC_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE_B64" \
    --query 'Certificate' \
    --output text > /tmp/cert.pem
  
  aws acm export-certificate \
    --certificate-arn $PUBLIC_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE_B64" \
    --query 'CertificateChain' \
    --output text > /tmp/chain.pem
  
  aws acm export-certificate \
    --certificate-arn $PUBLIC_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE_B64" \
    --query 'PrivateKey' \
    --output text > /tmp/encrypted_key.pem
  
  # Combine certificate and chain
  cat /tmp/cert.pem /tmp/chain.pem > /tmp/cert-with-chain.pem
  
  # Decrypt the private key
  openssl rsa -in /tmp/encrypted_key.pem -out /tmp/key.pem -passin pass:"$PASSPHRASE"
  
  # Create TLS secret in demo-app namespace
  kubectl create namespace demo-app --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls demo-app-tls \
    --cert=/tmp/cert-with-chain.pem \
    --key=/tmp/key.pem \
    --namespace demo-app \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Create RBAC for ingress controller to access demo-app namespace secrets
  kubectl create rolebinding ingress-nginx-secrets \
    --clusterrole=ingress-nginx \
    --serviceaccount=ingress-nginx:ingress-nginx \
    --namespace=demo-app \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Clean up temporary files
  rm -f /tmp/cert.pem /tmp/chain.pem /tmp/cert-with-chain.pem /tmp/key.pem /tmp/encrypted_key.pem
  
else
  echo "Using private certificate from AWS Private CA via cert-manager..."
fi

echo "Deploying a demo application..."
export LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME

if [[ -n "$PUBLIC_CERT_ARN" ]]; then
  export CERT_DOMAIN=$CERT_DOMAIN
  envsubst < "$(dirname "$0")/manifests/demo-app-public.yaml" | kubectl apply -f -
else
  envsubst < "$(dirname "$0")/manifests/demo-app-private.yaml" | kubectl apply -f -
fi

echo "=== Deployment Complete ==="
echo "Your TLS-enabled ingress is now available at:"
if [[ -n "$PUBLIC_CERT_ARN" && -n "$HOSTED_ZONE_ID" ]]; then
  echo "https://${CERT_DOMAIN}"
  echo "(DNS: $CERT_DOMAIN -> $LOAD_BALANCER_HOSTNAME)"
else
  echo "https://${LOAD_BALANCER_HOSTNAME}"
fi
echo ""
if [[ -z "$PUBLIC_CERT_ARN" ]]; then
  echo "Note: Since the certificate is issued by a private CA, your browser will show a warning."
  echo "To trust the certificate, you need to import the CA certificate into your trust store."
else
  echo "The certificate is issued by a public CA and should be trusted by browsers."
fi