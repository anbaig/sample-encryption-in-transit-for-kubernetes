#!/bin/bash
set -euo pipefail

REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-aws-pca-k8s-demo}
CERT_TYPE="public"
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
    --cert-type)
      CERT_TYPE="$2"
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

if [[ "$CERT_TYPE" != "public" && "$CERT_TYPE" != "private" ]]; then
  echo "Error: --cert-type must be either 'public' or 'private'"
  exit 1
fi

if [[ "$CERT_TYPE" == "public" && -z "$DOMAIN_NAME" ]]; then
  echo "Error: --domain-name is required for public certificates"
  exit 1
fi

echo "=== Deploying AWS Load Balancer Controller ==="
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
  curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
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
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n aws-load-balancer-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Install ACK Controller for ACM
echo "Installing ACK Controller for ACM..."
kubectl create namespace ack-system --dry-run=client -o yaml | kubectl apply -f -

# Create Pod Identity Association for ACM Controller
eksctl create podidentityassociation --cluster $CLUSTER_NAME --region $REGION \
  --namespace ack-system \
  --create-service-account \
  --service-account-name ack-acm-controller \
  --permission-policy-arns arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess 2>&1 | grep -v "already exists" || true

# Install ACM Controller
helm repo add ack https://aws-controllers-k8s.github.io/charts
helm repo update

helm upgrade --install ack-acm-controller ack/acm-chart \
  --namespace ack-system \
  --set aws.region=$REGION \
  --set serviceAccount.create=false \
  --set serviceAccount.name=ack-acm-controller

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
  --namespace kube-system \
  --create-service-account \
  --service-account-name external-dns \
  --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/AllowExternalDNSUpdates 2>&1 | grep -v "already exists" || true

# Install external-dns as EKS add-on
aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name external-dns --region $REGION --service-account-role-arn $(aws iam get-role --role-name eksctl-$CLUSTER_NAME-addon-iamserviceaccount-kube-system-external-dns-Role1 --query 'Role.Arn' --output text) 2>&1 | grep -v "already exists" || true

# Deploy demo application
echo "Deploying demo application..."
kubectl apply -f manifests/hello-world-app.yaml

# Deploy certificate and wait for it to be ready
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Deploying public certificate..."
  envsubst < manifests/public-certificate.yaml | kubectl apply -f -
  
  echo "Waiting for public certificate to be issued..."
  kubectl wait --for=condition=Ready certificate/public-cert -n demo-app --timeout=600s
  
  CERT_ARN=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.certificateARN}')
  SERVICE_NAME="hello-world-nlb"
else
  echo "Deploying private certificate..."
  kubectl apply -f manifests/private-certificate.yaml
  
  echo "Waiting for private certificate to be issued..."
  kubectl wait --for=condition=Ready certificate/private-cert -n demo-app --timeout=300s
  
  CERT_ARN=$(kubectl get certificate private-cert -n demo-app -o jsonpath='{.status.certificateARN}')
  SERVICE_NAME="hello-world-nlb-private"
fi

echo "Certificate ARN: $CERT_ARN"

# Deploy load balancer with actual certificate ARN
echo "Deploying load balancer with certificate..."
if [[ "$CERT_TYPE" == "public" ]]; then
  export CERT_ARN
  envsubst < manifests/public-load-balancer.yaml | kubectl apply -f -
else
  export CERT_ARN
  envsubst < manifests/private-load-balancer.yaml | kubectl apply -f -
fi

echo "Waiting for load balancer to be ready..."
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' service/$SERVICE_NAME -n demo-app --timeout=300s

LB_HOSTNAME=$(kubectl get service $SERVICE_NAME -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "=== Deployment Complete ==="
echo "Load Balancer Hostname: $LB_HOSTNAME"
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Test with: curl -k https://$DOMAIN_NAME"
else
  echo "Test with: curl -k https://$LB_HOSTNAME"
fi
