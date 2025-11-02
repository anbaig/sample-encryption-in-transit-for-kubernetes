# Deploy TLS-enabled NGINX Ingress

This module demonstrates how to deploy a TLS-enabled service to your cluster behind an AWS Network Load Balancer using NGINX Ingress Controller. It showcases TLS termination at the ingress level using certificates provisioned by AWS Certificate Manager.

## Prerequisites

Before running this module, you must first deploy the core PKI infrastructure:
```bash
../deploy-core-pki/deploy-core.sh --cluster-name <cluster-name> --region <region> --include-public-pki
```

## Overview

This module executes the following actions:
1. Installs the [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/) with Pod Identity
2. Deploys an AWS Network Load Balancer for internet-facing traffic
3. Creates either a public or private certificate using the ACM controller from core PKI module
4. For public certificates: Uses ExternalDNS with Route53 to automatically complete DNS validation challenges
5. Exports certificate from ACM and creates Kubernetes TLS secret for ingress termination
6. Deploys a demo application with TLS-enabled ingress configuration

## Important Note

**Certificate Renewal Limitation**: This approach is experimental for production use. While TLS termination works, there is no automated solution for updating the Kubernetes TLS secret when AWS Certificate Manager automatically renews certificates. Production deployments should implement a certificate synchronization mechanism.

## Usage

```bash
./deploy-ingress.sh [OPTIONAL PARAMETERS]
```

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)  
- `--domain`: Domain name for public certificate (e.g., ingress-demo.example.com)

### Examples

Deploy with private certificate (default):
```bash
./deploy-ingress.sh --cluster-name my-eks-cluster --region us-east-1
```

Deploy with public certificate:
```bash
./deploy-ingress.sh --cluster-name my-eks-cluster --region us-east-1 \
  --domain ingress-demo.example.com
```

## Key Features

- **Automatic Certificate Management**: Uses ACM Controller for certificate lifecycle
- **DNS Validation Automation**: ExternalDNS handles DNS validation records for public certificates
- **Secure Certificate Handling**: Certificate data processed in memory without temporary files
- **Complete Certificate Chain**: Exports and uses full certificate chain for proper validation
- **RBAC Integration**: Proper cluster-wide permissions for ingress controller

## Testing the Deployment

After deployment, access the demo application:

**Private certificates:**
```
https://<load-balancer-hostname>
```
*Note: Browser will show security warning due to private CA*

**Public certificates:**
```
https://<your-domain>
```
*Note: Create DNS record: your-domain → load-balancer-hostname*

### Certificate Verification

Verify the certificate being served:
```bash
echo | openssl s_client -connect <hostname>:443 -servername <domain> 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

## Troubleshooting

### Common Issues

**Certificate Validation Fails:**
- Ensure ExternalDNS has Route53 permissions
- Verify domain's hosted zone exists in Route53
- Check DNS validation records are created

**NGINX Controller Issues:**
- Verify `ingress-nginx` service account exists
- Check cluster RBAC permissions
- Ensure no conflicting ingress controllers

**SSL Certificate Errors:**
- Verify certificate includes full chain
- Check certificate is in ISSUED status
- Ensure domain matches hostname

**"Kubernetes Ingress Controller Fake Certificate":**
- Check TLS secret exists: `kubectl get secrets -n demo-app`
- Verify ingress references correct secret name
- Restart ingress controller: `kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx`

### Cleanup

Remove the deployment:
```bash
kubectl delete namespace demo-app
kubectl delete namespace ingress-nginx
kubectl delete clusterrole ingress-nginx-secrets
kubectl delete clusterrolebinding ingress-nginx-secrets
```

## Customization

Modify the manifest files to customize the deployment:
- `manifests/demo-app-public.yaml` - Public certificate configuration
- `manifests/demo-app-private.yaml` - Private certificate configuration  
- `manifests/ingress-rbac.yaml` - RBAC permissions
