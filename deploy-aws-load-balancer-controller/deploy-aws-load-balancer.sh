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

if [[ "$CERT_TYPE" == "public" && -z "$DOMAIN_NAME" ]]; then
  echo "Error: --domain-name is required for public certificates"
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

# Install ACK Controller for ACM
echo "Installing ACK Controller for ACM..."
kubectl create namespace ack-system --dry-run=client -o yaml | kubectl apply -f -

# Create IAM policy for ACM Controller if it doesn't exist
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/ACKACMControllerIAMPolicy >/dev/null 2>&1; then
  echo "Creating IAM policy for ACM Controller..."
  curl -o acm_policy.json https://raw.githubusercontent.com/aws-controllers-k8s/acm-controller/main/config/iam/recommended-inline-policy
  aws iam create-policy \
    --policy-name ACKACMControllerIAMPolicy \
    --policy-document file://acm_policy.json
  rm acm_policy.json
fi

# Create ACM PCA policy for private certificates if it doesn't exist -- This policy allows ACM to issue certificates from a Private CA
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/ACKACMControllerPCAPolicy >/dev/null 2>&1; then
  echo "Creating ACM PCA policy for ACM Controller..."
  cat > acm_pca_policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "acm-pca:IssueCertificate",
        "acm-pca:GetCertificate",
        "acm-pca:DescribeCertificateAuthority"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  aws iam create-policy \
    --policy-name ACKACMControllerPCAPolicy \
    --policy-document file://acm_pca_policy.json
  rm acm_pca_policy.json
fi

# Create ACM PCA policy for private certificates if it doesn't exist -- This allows ACM to issue certificates from an AWS Private CA
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerPCAPolicy >/dev/null 2>&1; then
  echo "Creating ACM PCA policy for AWS Load Balancer Controller..."
  cat > pca_policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "acm-pca:IssueCertificate",
        "acm-pca:GetCertificate",
        "acm-pca:DescribeCertificateAuthority"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerPCAPolicy \
    --policy-document file://pca_policy.json
  rm pca_policy.json
fi

# Create Pod Identity Association for ACM Controller
eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace ack-system \
  --create-service-account \
  --service-account-name ack-acm-controller \
  --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/ACKACMControllerIAMPolicy,arn:aws:iam::$AWS_ACCOUNT_ID:policy/ACKACMControllerPCAPolicy 2>&1 | grep -v "already exists" || true

# Install ACM Controller
echo "Getting latest ACM controller version..."
RELEASE_VERSION=$(curl -sL https://api.github.com/repos/aws-controllers-k8s/acm-controller/releases/latest | 
                  jq -r '.tag_name | ltrimstr("v")')

aws ecr-public get-login-password --region us-east-1 | 
helm registry login --username AWS --password-stdin public.ecr.aws

helm upgrade --install \
    --create-namespace \
    -n ack-system \
    ack-acm-controller \
    oci://public.ecr.aws/aws-controllers-k8s/acm-chart \
    --version=$RELEASE_VERSION \
    --set=aws.region=$REGION \
    --set=serviceAccount.create=false \
    --set=serviceAccount.name=ack-acm-controller \
    --set=reconcile.defaultResyncPeriod=30

# Install external-dns EKS add-on
echo "Installing external-dns EKS add-on..."

# Create IAM policy for external-dns if it doesn't exist
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AllowExternalDNSUpdates >/dev/null 2>&1; then
  echo "Creating IAM policy for external-dns..."
  cat > external-dns-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
  aws iam create-policy \
    --policy-name AllowExternalDNSUpdates \
    --policy-document file://external-dns-policy.json
  rm external-dns-policy.json
fi

# Create Pod Identity Association for external-dns
eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace external-dns \
  --create-service-account \
  --service-account-name external-dns \
  --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/AllowExternalDNSUpdates 2>&1 | grep -v "already exists" || true

# Install external-dns as EKS add-on with CRD source support
echo "Installing external-dns EKS add-on with CRD sources..."
aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name external-dns --region $REGION \
  --configuration-values '{"sources":["service","ingress","crd"]}' 2>&1 | grep -v "already exists" || true

# Create additional RBAC permissions for external-dns to read DNSEndpoints across namespaces
echo "Creating RBAC permissions for external-dns to access DNSEndpoints..."
kubectl apply -f manifests/external-dns-rbac.yaml

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
  echo "Test with: curl -k https://$LB_HOSTNAME/hello-world"
  echo "Test with: curl -k https://$LB_HOSTNAME/certificate-status"
fi
