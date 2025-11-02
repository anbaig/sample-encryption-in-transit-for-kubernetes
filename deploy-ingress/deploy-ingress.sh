#!/bin/bash
set -euo pipefail

# Default values
REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
DOMAIN_NAME=""
CERT_TYPE="private"

# Function to wait for certificate to be issued
wait_for_certificate_issued() {
  local cert_name="$1"
  
  echo "Waiting for certificate to be issued..."
  while true; do
    CERT_STATUS=$(kubectl get certificate "$cert_name" -n demo-app -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    if [[ "$CERT_STATUS" == "ISSUED" ]]; then
      echo "Certificate issued successfully"
      break
    fi
    echo "Certificate status: $CERT_STATUS - waiting for ISSUED..."
    sleep 15
  done
}

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
    --domain)
      DOMAIN_NAME="$2"
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

echo "=== Deploying TLS-enabled Ingress ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Certificate Type: $CERT_TYPE"
if [[ -n "$DOMAIN_NAME" ]]; then
  echo "Domain: $DOMAIN_NAME"
else
  echo "Domain: Will use load balancer hostname"
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
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing" \
  --set controller.service.enableHttp=false \

echo "Waiting for the load balancer to be provisioned..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

LOAD_BALANCER_HOSTNAME=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load balancer hostname: $LOAD_BALANCER_HOSTNAME"

# Handle certificate provisioning based on type
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Deploying public certificate..."
  export DOMAIN_NAME
  envsubst < manifests/public-certificate.yaml | kubectl apply -f -
  
  echo "Waiting for certificate to be created in ACM..."
  kubectl wait --for=condition=ACK.ResourceSynced certificate/public-cert-ingress -n demo-app --timeout=300s
  
  echo "Waiting for DNS validation records to be populated..."
  while true; do
    VALIDATION_NAME=$(kubectl get certificate public-cert-ingress -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.name}' 2>/dev/null || echo "")
    VALIDATION_VALUE=$(kubectl get certificate public-cert-ingress -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.value}' 2>/dev/null || echo "")
    VALIDATION_TYPE=$(kubectl get certificate public-cert-ingress -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.type_}' 2>/dev/null || echo "")
    
    if [[ -n "$VALIDATION_NAME" && -n "$VALIDATION_VALUE" && -n "$VALIDATION_TYPE" ]]; then
      echo "DNS validation records populated successfully"
      break
    fi
    
    echo "Waiting for DNS validation records to be available..."
    sleep 10
  done
  
  # Remove trailing dot from VALIDATION_VALUE
  VALIDATION_VALUE=${VALIDATION_VALUE%.}
  
  echo "Creating DNS validation record: $VALIDATION_NAME -> $VALIDATION_VALUE"
  
  # Create DNSEndpoint for external-dns to pick up
  export VALIDATION_NAME VALIDATION_VALUE VALIDATION_TYPE
  envsubst < manifests/dns-validation-record.yaml | kubectl apply -f -
  
  wait_for_certificate_issued "public-cert-ingress"
  
  CERT_DOMAIN="$DOMAIN_NAME"

  # Export certificate with full chain for Kubernetes secret
  echo "Exporting certificate with full chain for Kubernetes..."
  
  # Currently the ACK ACM controller doesn't support creating exportable certificates
  # To get around this, we can piggy back off of the ACK created certificate domain validation
  # completition by requesting a certificate with the same domain but export enabled to allow
  # us to have a exportable certificate for the same domain
  
  echo "Requesting new exportable certificate for domain: $CERT_DOMAIN"
  EXPORTABLE_CERT_ARN=$(aws acm request-certificate \
    --domain-name "$CERT_DOMAIN" \
    --validation-method DNS \
    --options Export=ENABLED \
    --region $REGION \
    --query 'CertificateArn' \
    --idempotency-token 'PublicCertIngress' \
    --output text)
  
  echo "Waiting for certificate validation to complete..."
  aws acm wait certificate-validated \
    --certificate-arn "$EXPORTABLE_CERT_ARN" \
    --region $REGION || true
  
  echo "Certificate validated successfully: $EXPORTABLE_CERT_ARN"
  
  echo "Exporting $EXPORTABLE_CERT_ARN into Kubernetes secret"
  
  # Generate random passphrase for certificate export
  PASSPHRASE_PLAIN=$(openssl rand -hex 16)
  PASSPHRASE=$(echo -n "$PASSPHRASE_PLAIN" | base64)
  echo "Using randomly generated passphrase for certificate export"
  
  # Export and process certificate data directly
  echo "Exporting certificate data..."
  CERT_DATA=$(aws acm export-certificate \
    --certificate-arn $EXPORTABLE_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE" \
    --query 'Certificate' \
    --output text) || { echo "Certificate export failed"; exit 1; }
  
  echo "Exporting certificate chain..."
  CHAIN_DATA=$(aws acm export-certificate \
    --certificate-arn $EXPORTABLE_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE" \
    --query 'CertificateChain' \
    --output text) || { echo "Certificate chain export failed"; exit 1; }
  
  echo "Exporting private key..."
  ENCRYPTED_KEY=$(aws acm export-certificate \
    --certificate-arn $EXPORTABLE_CERT_ARN \
    --region $REGION \
    --passphrase "$PASSPHRASE" \
    --query 'PrivateKey' \
    --output text) || { echo "Private key export failed"; exit 1; }
  
  # Decrypt private key
  DECRYPTED_KEY=$(echo "$ENCRYPTED_KEY" | openssl rsa -passin pass:"$PASSPHRASE_PLAIN" 2>&1)
  
  echo "Combining certificate with chain..."
  CERT_WITH_CHAIN="${CERT_DATA}"$'\n'"${CHAIN_DATA}"
  
  echo "Creating Kubernetes TLS secret..."
  kubectl create secret tls demo-app-tls-public \
    --cert=<(echo "$CERT_WITH_CHAIN") \
    --key=<(echo "$DECRYPTED_KEY") \
    --namespace demo-app \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Kubernetes TLS secret created successfully"
  
  # Create RBAC for ingress controller to access secrets
  echo "Creating RBAC for ingress controller..."
  kubectl apply -f "$(dirname "$0")/manifests/ingress-rbac.yaml"
else
  echo "Using private certificate from AWS Private CA via cert-manager..."
fi

echo "Deploying a demo application..."
export LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME

# Determine the hostname to use
if [[ -n "$DOMAIN_NAME" ]]; then
  CERT_DOMAIN="$DOMAIN_NAME"
else
  CERT_DOMAIN="$LOAD_BALANCER_HOSTNAME"
fi

export CERT_DOMAIN
if [[ "$CERT_TYPE" == "public" ]]; then
  envsubst < "$(dirname "$0")/manifests/demo-app-public.yaml" | kubectl apply -f -
else
  envsubst < "$(dirname "$0")/manifests/demo-app-private.yaml" | kubectl apply -f -
fi

echo "=== Deployment Complete ==="
echo "Your TLS-enabled ingress is now available at:"
echo "https://${CERT_DOMAIN}"
if [[ -n "$DOMAIN_NAME" && "$CERT_DOMAIN" != "$LOAD_BALANCER_HOSTNAME" ]]; then
  echo "(Note: If you have external-dns configured, the DNS record should be created automatically."
  echo " Otherwise, you need to manually create a DNS record: $CERT_DOMAIN -> $LOAD_BALANCER_HOSTNAME)"
fi
echo ""
if [[ "$CERT_TYPE" == "private" ]]; then
  echo "Note: Since the certificate is issued by a private CA, your browser will show a warning."
  echo "To trust the certificate, you need to import the CA certificate into your trust store."
else
  echo "The certificate is issued by a public CA and should be trusted by browsers."
fi
