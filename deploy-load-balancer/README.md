# Deploy AWS Application Load Balancer with TLS Certificates

This module deploys the AWS Load Balancer Controller and demonstrates TLS termination at the Application Load Balancer level using certificates provisioned by the core PKI module. It showcases path-based routing with TLS encryption using certificates managed by ACM.

## Prerequisites

Before running this module, you must first deploy the core PKI infrastructure:
```bash
../deploy-core-pki/deploy-core.sh --cluster-name <cluster-name> --region <region>
```

## Overview

This module executes the following actions:
1. Installs the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) using Pod Identity
2. Deploys demo applications (hello-world and foobar services)
3. Creates either a public or private certificate using the ACM controller from core PKI module
4. For public certificates: Uses ExternalDNS with Route53 to automatically complete DNS validation challenges by creating the required CNAME records for certificate issuance
5. Configures an Application Load Balancer with HTTPS-only access and path-based routing

## Usage

```bash
./deploy-load-balancer.sh [REQUIRED/OPTIONAL PARAMETERS]
```

### Required Parameters

- `--cert-type`: Certificate type - 'public' or 'private'
- `--domain-name`: Domain name for the certificate (e.g., k8-alb-demo.example.com)

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--private-ca-arn`: ARN of existing AWS Private CA (required for private certificates if not using deployed Private CA)

### Examples

Deploy with public certificate and automatic DNS validation:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type public --domain-name k8-alb-demo.example.com
```

Deploy with private certificate (requires Private CA):
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type private --domain-name k8-alb-demo.example.com \
  --private-ca-arn arn:aws:acm-pca:us-west-2:123456789012:certificate-authority/12345678-1234-1234-1234-123456789012
```

Deploy with private certificate using deployed Private CA:
```bash
./deploy-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 \
  --cert-type private --domain-name k8-alb-demo.example.com
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
curl -k https://your-domain.com/hello-world
curl -k https://you-domain.com/foobar
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
- Note: external-dns is installed by the core PKI module

## Customization

Modify the `manifests/hello-world-app.yaml` file to customize the demo applications or add your own applications with different paths and services.
