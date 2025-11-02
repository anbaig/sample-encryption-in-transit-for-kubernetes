# Deploy AWS Load Balancer Controller with TLS Certificates

This module deploys the AWS Load Balancer Controller and demonstrates TLS termination at the Application Load Balancer level using either public or private certificates managed by AWS Certificate Manager (ACM). It showcases automatic DNS validation, certificate provisioning, and path-based routing with TLS encryption.

## Overview

This module executes the following actions:
1. Installs the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) using Pod Identity
2. Installs the [ACK Controller for ACM](https://aws-controllers-k8s.github.io/community/reference/acm/) to manage certificates
3. Installs the external-dns EKS add-on for DNS management and certificate validation
4. Deploys demo applications (hello-world and foobar services)
5. Creates either a public or private certificate using ACM with automatic validation
6. Configures an Application Load Balancer with HTTPS-only access and path-based routing

## Usage

```bash
./deploy-aws-load-balancer.sh [REQUIRED/OPTIONAL PARAMETERS]
```

### Required Parameters for Public Certificates

- `--cert-type public`: Use public certificates
- `--domain-name`: Domain name for the certificate (e.g., k8-alb-demo.example.com)

### Required Parameters for Private Certificates

- `--cert-type private`: Use private certificates
- `--private-ca-arn`: ARN of existing AWS Private CA (or use deployed Private CA from core-pki module)

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)

### Examples

Deploy with public certificate and automatic DNS validation:
```bash
./deploy-aws-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type public --domain-name k8-alb-demo.example.com
```

Deploy with private certificate (requires Private CA):
```bash
./deploy-aws-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type private --private-ca-arn arn:aws:acm-pca:us-west-2:123456789012:certificate-authority/12345678-1234-1234-1234-123456789012
```

Deploy with private certificate using deployed Private CA:
```bash
./deploy-aws-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type private
```

## Testing the Application

After deployment completes, test the applications:

**For Public Certificates:**
```bash
curl https://your-domain.com/hello-world
curl https://your-domain.com/foobar
```

**For Private Certificates:**
```bash
# Get the load balancer hostname from the script output
curl -k https://LOAD-BALANCER-HOSTNAME/hello-world
curl -k https://LOAD-BALANCER-HOSTNAME/foobar
```

## Troubleshooting

### Certificate Issues
- Check certificate status: `kubectl describe certificate -n demo-app`
- Verify ACM controller logs: `kubectl logs -n ack-system -l app.kubernetes.io/name=acm-chart`
- Check certificate validation: `kubectl get certificate -n demo-app -o yaml`

### Load Balancer Issues
- Check AWS Load Balancer Controller logs: `kubectl logs -n aws-load-balancer-system -l app.kubernetes.io/name=aws-load-balancer-controller`
- Verify ingress status: `kubectl describe ingress hello-world-alb -n demo-app`
- Check target group health in AWS Console

### DNS Issues (Public Path)
- Check external-dns logs: `kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns`
- Verify Route53 records in AWS Console
- Check DNSEndpoint resources: `kubectl get dnsendpoint -A`

## Customization

Modify the `manifests/hello-world-app.yaml` file to customize the demo applications or add your own applications with different paths and services.
