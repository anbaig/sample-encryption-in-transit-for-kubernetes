# Deploy Load Balancer with TLS

This module demonstrates how to deploy a Network Load Balancer (NLB) that points to your EKS cluster's ingress controller with TLS termination.

## Overview

This setup:
1. Creates a Network Load Balancer with TLS listener
2. Provisions either a public or private certificate via AWS Certificate Manager
3. Configures the NLB to forward traffic to the NGINX ingress controller
4. Supports both public certificates (existing ACM) and private certificates (AWS Private CA)
5. Optionally creates DNS records for public certificates

## Prerequisites

- EKS cluster created using `create-cluster/`
- For private certificates: AWS Private CA ARN (can be obtained from `deploy-core-pki/` deployment)
- For public certificates: Existing certificate in ACM in ISSUED status

## Usage

```bash
./deploy-load-balancer.sh [OPTIONAL PARAMETERS]
```

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--public-cert-arn`: ARN of existing public certificate (if provided, uses public certificate)
- `--private-ca-arn`: ARN of AWS Private CA (required for private certificates)
- `--hosted-zone-id`: Route53 hosted zone ID for automatic DNS record creation (requires public-cert-arn)

### Examples

Deploy with private certificate:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-east-1 \
  --private-ca-arn arn:aws:acm-pca:us-west-1:123456789012:certificate-authority/12345678-1234-1234-1234-123456789012
```

Deploy with existing public certificate:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-east-1 \
  --public-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012
```

Deploy with public certificate and automatic DNS record creation:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-east-1 \
  --public-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012 \
  --hosted-zone-id Z1234567890ABC
```

### Getting Private CA ARN

If you have already deployed the core PKI using `deploy-core-pki/`, you can get the Private CA ARN with:

```bash
kubectl get awspcaclusterissuer aws-pca-cluster-issuer -o jsonpath='{.spec.arn}'
```

## Certificate Types

### Private Certificate
- Uses AWS Private CA via AWS Certificate Manager
- Requires importing the CA certificate into client trust stores
- Suitable for internal/development workloads
- More cost-effective for internal use

### Public Certificate
- Uses an existing public certificate from AWS Certificate Manager
- Certificate must be in ISSUED status before deployment
- Trusted by all browsers and clients
- Suitable for production workloads
- Optionally creates DNS CNAME record if hosted zone ID provided

## Testing the Load Balancer

After deployment, the script will output the hostname of the Network Load Balancer. You can access the demo application using:

```
https://<nlb-hostname>
```

For public certificates with DNS records created, you can also access via the certificate domain name.

## Architecture

The load balancer sits in front of your ingress controller:

```
Internet → NLB (TLS termination) → NGINX Ingress Controller (HTTP) → Application Pods
```

This provides TLS termination at the AWS infrastructure level while allowing the ingress controller to handle HTTP routing.
