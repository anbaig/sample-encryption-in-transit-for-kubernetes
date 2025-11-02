#!/bin/bash
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
DOMAIN_NAME=""
PRIVATE_CA_ARN=""

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
    --cert-type)
      CERT_TYPE="$2"
      shift 2
      ;;
    --domain-name)
      DOMAIN_NAME="$2"
      shift 2
      ;;
    --private-ca-arn)
      PRIVATE_CA_ARN="$2"
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

if [[ -z "$DOMAIN_NAME" ]]; then
  echo "Error: --domain-name is required for both public and private certificates"
  exit 1
fi

echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Certificate Type: $CERT_TYPE"
if [[ -n "$DOMAIN_NAME" ]]; then
  echo "Domain Name: $DOMAIN_NAME"
fi

export REGION
export AWS_REGION=$REGION

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Install AWS Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."
kubectl create namespace aws-load-balancer-system --dry-run=client -o yaml | kubectl apply -f -

# Create IAM policy if it doesn't exist
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy >/dev/null 2>&1; then
  echo "Creating IAM policy for AWS Load Balancer Controller..."
  curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
  rm iam_policy.json
fi

# Create Pod Identity Association for AWS Load Balancer Controller
echo "Creating Pod Identity Association for AWS Load Balancer Controller..."
eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace aws-load-balancer-system \
  --create-service-account \
  --service-account-name aws-load-balancer-controller \
  --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy 2>&1 | grep -v "already exists" || true

# Install AWS Load Balancer Controller using Helm
echo "Installing AWS Load Balancer Controller using Helm..."
helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n aws-load-balancer-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$VPC_ID

# Wait for AWS Load Balancer Controller to be ready
echo "Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available deployment/aws-load-balancer-controller -n aws-load-balancer-system --timeout=300s

# Deploy demo application
echo "Deploying demo application..."
kubectl apply -f manifests/hello-world-app.yaml

# Deploy certificate and wait for it to be ready
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Deploying public certificate..."
  export DOMAIN_NAME
  envsubst < manifests/public-certificate.yaml | kubectl apply -f -
  
  echo "Waiting for certificate to be created in ACM..."
  kubectl wait --for=condition=ACK.ResourceSynced certificate/public-cert -n demo-app --timeout=300s
  
  echo "Waiting for DNS validation records to be populated..."
  while true; do
    VALIDATION_NAME=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.name}' 2>/dev/null || echo "")
    VALIDATION_VALUE=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.value}' 2>/dev/null || echo "")
    VALIDATION_TYPE=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.domainValidations[0].resourceRecord.type_}' 2>/dev/null || echo "")
    
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
  
  wait_for_certificate_issued "public-cert"
  
  CERT_ARN=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.ackResourceMetadata.arn}')
else
  echo "Getting Private CA ARN..."
  if [[ -n "$PRIVATE_CA_ARN" ]]; then
    CA_ARN="$PRIVATE_CA_ARN"
    echo "Using provided Private CA: $CA_ARN"
  else
    CA_ARN=$(kubectl get certificateauthority root-ca -o jsonpath='{.status.ackResourceMetadata.arn}' 2>/dev/null)
    if [[ -z "$CA_ARN" ]]; then
      echo "Error: Could not find root-ca CertificateAuthority resource. Please run deploy-core-pki first or provide --private-ca-arn."
      exit 1
    fi
    echo "Using Private CA from root-ca resource: $CA_ARN"
  fi
  
  echo "Deploying private certificate..."
  export CA_ARN DOMAIN_NAME
  envsubst < manifests/private-certificate.yaml | kubectl apply -f -
  
  wait_for_certificate_issued "private-cert"
  
  CERT_ARN=$(kubectl get certificate private-cert -n demo-app -o jsonpath='{.status.ackResourceMetadata.arn}')
fi

echo "Certificate ARN: $CERT_ARN"

# Deploy load balancer with actual certificate ARN
echo "Deploying load balancer with certificate..."
export CERT_ARN DOMAIN_NAME
envsubst < manifests/load-balancer.yaml | kubectl apply -f -

echo "Waiting for load balancer to be ready..."
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' ingress/hello-world-alb -n demo-app --timeout=300s

LB_HOSTNAME=$(kubectl get ingress hello-world-alb -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "=== Deployment Complete ==="
echo "Load Balancer Hostname: $LB_HOSTNAME"
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Test with: curl -k https://$DOMAIN_NAME/hello-world"
  echo "Test with: curl -k https://$DOMAIN_NAME/certificate-status"
else
  echo "Test with: curl -k https://$DOMAIN_NAME/hello-world"
  echo "Test with: curl -k https://$DOMAIN_NAME/certificate-status"
fi
