# Deploy TLS-enabled Ingress

This module demonstrates how to deploy a TLS-enabled service to your cluster, behind an AWS Load Balancer.

## Prerequisites

Before running this script, ensure your EKS cluster meets these requirements:

### Required Cluster State
- **Clean cluster**: No existing NGINX ingress controllers or conflicting ingress resources
- **RBAC permissions**: Your kubectl context must have cluster-admin permissions
- **AWS Load Balancer Controller**: Should NOT be installed (this script uses NGINX ingress with NLB)
- **Service account**: No existing `ingress-nginx` service account in the `ingress-nginx` namespace

### Required Tools
- `kubectl` configured for your EKS cluster
- `eksctl` installed and configured
- `helm` v3.x installed
- `aws` CLI configured with appropriate permissions
- `openssl` for certificate processing

### AWS Permissions Required
- ACM: `DescribeCertificate`, `ExportCertificate`
- Route53: `ChangeResourceRecordSets` (if using `--hosted-zone-id`)
- EKS: `DescribeCluster`
- IAM: `CreateRole`, `AttachRolePolicy` (for pod identity association)

### Cluster State Verification

Before running the script, verify your cluster state:

```bash
# Check for existing ingress controllers
kubectl get pods -A | grep ingress

# Check for existing ingress resources
kubectl get ingress -A

# Verify no conflicting load balancers
kubectl get svc -A | grep LoadBalancer

# Check RBAC permissions
kubectl auth can-i create clusterroles
kubectl auth can-i create clusterrolebindings
```

If any of these return existing resources, clean them up first or expect conflicts.

### Certificate Requirements
- For public certificates: Must be in `ISSUED` status in ACM
- Certificate domain must match the intended hostname
- Certificate must be in the same region as your EKS cluster

## Overview

This setup:
1. Installs the NGINX ingress controller with proper RBAC
2. Deploys an AWS Network Load Balancer
3. Deploys a demo application to the cluster
4. Automatically provisions a certificate (public or private)
5. Configures the ingress to process and terminate encrypted TLS connections with full certificate chain

## Usage

```bash
./deploy-ingress.sh [OPTIONAL PARAMETERS]
```

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--public-cert-arn`: ARN of existing public certificate (if provided, uses public certificate)
- `--hosted-zone-id`: Route53 hosted zone ID for DNS record creation (requires public certificate)

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

Deploy with public certificate and DNS automation:
```bash
./deploy-ingress.sh --cluster-name my-eks-cluster --region us-east-1 \
  --public-cert-arn arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012 \
  --hosted-zone-id Z1D633PJN98FT9
```

## Testing the Ingress

After deployment, the script will output the hostname of the load balancer. You can access the demo application using:

```
https://<load-balancer-hostname>
```

If you provided a `--hosted-zone-id`, the script will also create a DNS record and you can access the application using your custom domain:

```
https://<your-certificate-domain>
```

**Note for private certificates**: Since the certificate is issued by a private CA, your browser will show a warning. To trust the certificate, you need to import the CA certificate into your trust store.

**Note for public certificates**: The certificate should be trusted by browsers.

## DNS Automation

When using public certificates with the `--hosted-zone-id` parameter, the script automatically:
1. Extracts the domain name from the ACM certificate
2. Creates a CNAME record in Route53 pointing to the load balancer
3. Displays the custom domain URL in the final output

## Key Improvements

This script has been updated to address common deployment issues:

1. **Complete Certificate Chain**: Exports and uses the full certificate chain (leaf + intermediate + root) for proper browser trust
2. **Proper Namespace Management**: Places TLS secrets in the `ingress-nginx` namespace for correct access permissions
3. **Cross-Namespace Service Access**: Creates ExternalName service to allow ingress in `ingress-nginx` namespace to access apps in `demo-app` namespace
4. **Modern Ingress Configuration**: Uses `ingressClassName` instead of deprecated annotations
5. **Domain-Based Routing**: Uses certificate domain name for ingress rules instead of load balancer hostname

## Troubleshooting

### Common Issues

1. **SSL Certificate Errors**: 
   - Ensure the certificate includes the full chain (leaf + intermediate + root)
   - Verify the certificate domain matches your hostname
   - Check that the certificate is in ISSUED status

2. **NGINX Controller Not Starting**:
   - Verify the `ingress-nginx` service account exists
   - Check cluster RBAC permissions
   - Ensure no conflicting ingress controllers are installed

3. **Certificate Chain Issues**:
   - If browsers show "untrusted certificate" errors, verify the full certificate chain is included
   - Check that the TLS secret contains all certificates: `kubectl get secret demo-app-tls -n ingress-nginx -o yaml`
   - Ensure the certificate was exported with both Certificate and CertificateChain from ACM

4. **DNS Resolution Issues**:
   - Verify Route53 hosted zone permissions
   - Check that the CNAME record was created correctly
   - Allow time for DNS propagation (up to 5 minutes)

5. **Load Balancer Not Accessible**:
   - Verify security groups allow traffic on ports 80/443
   - Check that the NLB was created successfully
   - Ensure the target groups are healthy

### Cleanup

To remove the deployment:
```bash
kubectl delete namespace demo-app
kubectl delete namespace ingress-nginx
```

## Customization

Modify the `manifests/demo-app.yaml` file to customize the demo application or add your own applications.