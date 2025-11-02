#!/bin/bash
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
EXISTING_CA_ARN=""
INCLUDE_PUBLIC_PKI=false

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
    --existing-ca-arn)
      EXISTING_CA_ARN="$2"
      shift 2
      ;;
    --include-public-pki)
      INCLUDE_PUBLIC_PKI=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "=== Deploying core tools and AWS Private CA ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
export REGION
export AWS_REGION=$REGION

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "AWS Account ID: $AWS_ACCOUNT_ID"

if [ -z "$EXISTING_CA_ARN" ]; then
  echo "Installing AWS Private CA Controller for Kubernetes..."
  kubectl create namespace ack-system --dry-run=client -o yaml | kubectl apply -f -

  eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
    --namespace ack-system \
    --create-service-account \
    --service-account-name ack-acmpca-controller \
    --permission-policy-arns arn:aws:iam::aws:policy/AWSPrivateCAFullAccess 2>&1 | grep -v "already exists" || true

  sleep 15

  RELEASE_VERSION=$(curl -sL https://api.github.com/repos/aws-controllers-k8s/acmpca-controller/releases/latest | 
                    jq -r '.tag_name | ltrimstr("v")')

  aws ecr-public get-login-password --region us-east-1 | 
  helm registry login --username AWS --password-stdin public.ecr.aws

  helm upgrade --install \
      --create-namespace \
      -n ack-system \
      ack-acmpca-controller \
      oci://public.ecr.aws/aws-controllers-k8s/acmpca-chart \
      --version=$RELEASE_VERSION \
      --set=aws.region=$AWS_REGION \
      --set=serviceAccount.create=false \
      --set=serviceAccount.name=ack-acmpca-controller

  kubectl apply -f $(dirname "$0")/manifests/private-ca.yaml
  kubectl wait --for=jsonpath='{.status.status}'=ACTIVE certificateauthority root-ca --timeout=120s

  CA_ARN=$(kubectl get certificateauthority root-ca -o json | jq -r '.status.ackResourceMetadata.arn')
else
  CA_ARN=$EXISTING_CA_ARN
fi

echo "CA ARN: $CA_ARN"
export CA_ARN

echo "Installing cert-manager..."
eksctl create addon --name cert-manager --cluster $CLUSTER_NAME --region $REGION
kubectl wait --for=condition=ready pods --all -n cert-manager --timeout=120s

echo "Installing AWS Private CA Connector for Kubernetes..."
kubectl create namespace aws-privateca-issuer --dry-run=client -o yaml | kubectl apply -f -

eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace aws-privateca-issuer \
  --create-service-account \
  --service-account-name aws-privateca-issuer \
  --permission-policy-arns arn:aws:iam::aws:policy/AWSPrivateCAConnectorForKubernetesPolicy 2>&1 | grep -v "already exists" || true

sleep 15

kubectl label serviceaccount aws-privateca-issuer -n aws-privateca-issuer app.kubernetes.io/managed-by-
eksctl create addon --name aws-privateca-connector-for-kubernetes --cluster $CLUSTER_NAME --region $REGION
kubectl wait --for=condition=ready pods --all -n aws-privateca-issuer --timeout=180s

echo "Creating AWS PCA Cluster Issuer..."
envsubst < "$(dirname "$0")/manifests/cluster-issuer.yaml" | kubectl apply -f -

if [[ "$INCLUDE_PUBLIC_PKI" == "true" ]]; then
  # Currently the ACK Private CA Resource does not support giving AWS Certificate Manager the permissions to do automated
  # renewals on private certificates: https://github.com/aws-controllers-k8s/community/issues/2668
  aws acm-pca create-permission --certificate-authority-arn $CA_ARN --principal acm.amazonaws.com \
  --actions IssueCertificate GetCertificate ListPermissions --region $REGION 2>&1 | grep -v "PermissionAlreadyExistsException" || true

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

  # Create ACM PCA policy for private certificates if it doesn't exist. This is needed for AWS Certificate Manager to issue private certificates.
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
  kubectl apply -f "$(dirname "$0")/manifests/external-dns-rbac.yaml"
fi

echo "=== Deployment Complete ==="
echo "Your Kubernetes cluster is now configured with:"
echo "- AWS Private CA integration via cert-manager"
if [[ "$INCLUDE_PUBLIC_PKI" == "true" ]]; then
  echo "- ACM Controller for certificate management"
  echo "- external-dns for Certificate DNS validation automation"
fi
echo "You can now issue certificates using the 'aws-pca-cluster-issuer' issuer."
echo "Example:"
echo "  kubectl apply -f $(dirname "$0")/manifests/example-certificate.yaml"
