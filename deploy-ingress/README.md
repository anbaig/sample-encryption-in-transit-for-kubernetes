# Deploy TLS-enabled Ingress

This module demonstrates how to deploy a TLS-enabled service to your cluster, behind an AWS Load Balancer.

## Overview

This setup:
1. Installs the NGINX ingress controller
2. Deploys an AWS Network Load Balancer
3. Deploys a demo application to the cluster
4. Automatically provisions a certificate (public or private)
5. Configures the ingress to process and terminate encrypted TLS connections

## Usage

```bash
./deploy-ingress.sh [OPTIONAL PARAMETERS]
```

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--public-cert-arn`: ARN of existing public certificate (if provided, uses public certificate)

### Examples

Deploy with private certificate (default):
```bash
./deploy-ingress.sh --cluster-name my-eks-cluster --region us-east-1
```

Deploy with existing public certificate:
```bash
./deploy-ingress.sh --cluster-name my-eks-cluster --region us-east-1 \
  --public-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012
```

## Testing the Ingress

After deployment, the script will output the hostname of the load balancer. You can access the demo application using:

```
https://<load-balancer-hostname>
```

**Note for private certificates**: Since the certificate is issued by a private CA, your browser will show a warning. To trust the certificate, you need to import the CA certificate into your trust store.

**Note for public certificates**: The certificate should be trusted by browsers.

## Customization

Modify the `manifests/demo-app.yaml` file to customize the demo application or add your own applications.