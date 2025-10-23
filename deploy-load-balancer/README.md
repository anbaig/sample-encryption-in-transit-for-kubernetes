# Deploy Load Balancer with TLS

This module demonstrates how to deploy an Application Load Balancer (ALB) that points to your EKS cluster's ingress controller with TLS termination.

## Overview

This setup:
1. Creates an Application Load Balancer with TLS listener
2. Provisions either a public or private certificate via AWS Certificate Manager
3. Configures the ALB to forward traffic to the existing ingress controller
4. Supports both public certificates (ACM) and private certificates (AWS Private CA)

## Prerequisites

- EKS cluster created using `create-cluster/`
- Ingress controller deployed using `deploy-ingress/`
- For private certificates: AWS Private CA deployed using `deploy-core-pki/`
- AWS Load Balancer Controller installed on the cluster

## Usage

```bash
./deploy-load-balancer.sh [OPTIONAL PARAMETERS]
```

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--cert-type`: Certificate type - 'public' or 'private' (default: private)

### Examples

Deploy with private certificate (default):
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-east-1
```

Deploy with public certificate:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-east-1 --cert-type public
```

## Certificate Types

### Public Certificate
- Uses AWS Certificate Manager to issue a public certificate
- Automatically validated via DNS
- Trusted by all browsers and clients
- Suitable for production workloads

### Private Certificate
- Uses AWS Private CA via AWS Certificate Manager
- Requires importing the CA certificate into client trust stores
- Suitable for internal/development workloads
- More cost-effective for internal use

## Testing the Load Balancer

After deployment, the script will output the hostname of the Application Load Balancer. You can access the demo application using:

```
https://<alb-hostname>
```

## Architecture

The load balancer sits in front of your ingress controller:

```
Internet → ALB (TLS termination) → Ingress Controller → Application Pods
```

This provides an additional layer of load balancing and TLS termination at the AWS infrastructure level.
