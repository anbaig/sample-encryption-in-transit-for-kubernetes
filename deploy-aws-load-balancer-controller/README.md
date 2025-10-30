# Deploy AWS Load Balancer Controller with TLS Certificates

This module deploys the AWS Load Balancer Controller and demonstrates TLS termination at the load balancer level using either public or private certificates managed by AWS Certificate Manager (ACM). It showcases how to integrate Kubernetes services with AWS networking services for secure, production-ready applications.

## Overview

This module executes the following actions:
1. Installs the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) using Pod Identity
2. Installs the [ACK Controller for ACM](https://aws-controllers-k8s.github.io/community/reference/acm/) to manage certificates
3. Installs the external-dns EKS add-on for DNS management
4. Deploys a hello world application
5. Creates either a public or private certificate using ACM
6. Configures a Network Load Balancer with TLS termination

## Prerequisites

- EKS cluster with Pod Identity enabled
- For public certificates: A Route53 hosted zone for your domain
- For private certificates: AWS Private CA deployed (use the [deploy-core-pki](../deploy-core-pki/README.md) module)

## Usage

```bash
./deploy-aws-load-balancer.sh [REQUIRED/OPTIONAL PARAMETERS]
```

### Required Parameters for Public Certificates

- `--cert-type public`: Use public certificates
- `--domain-name`: Domain name for the certificate (e.g., example.com)

### Optional Parameters

- `--cluster-name`: Name of the EKS cluster (default: aws-pca-k8s-demo)
- `--region`: AWS region (default: us-east-1)
- `--cert-type`: Certificate type - 'public' or 'private' (default: public)

### Examples

Deploy with public certificate:
```bash
./deploy-aws-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 --cert-type public --domain-name example.com
```

Deploy with private certificate (requires Private CA):
```bash
./deploy-aws-load-balancer.sh --cluster-name my-eks-cluster --region us-west-2 --cert-type private
```

## Public Path Workflow

1. **Certificate Creation**: Creates a public certificate in ACM using DNS validation
2. **DNS Validation**: external-dns automatically creates the required DNS validation records in Route53
3. **Load Balancer**: Deploys a Network Load Balancer with the public certificate for TLS termination
4. **DNS Record**: external-dns creates an A record pointing to the load balancer
5. **Application Access**: The hello world application is accessible via HTTPS using the public certificate

## Private Path Workflow

1. **Certificate Creation**: Creates a private certificate in ACM using the Private CA
2. **Load Balancer**: Deploys an internal Network Load Balancer with the private certificate for TLS termination
3. **Application Access**: The hello world application is accessible via HTTPS using the private certificate (requires trust of the Private CA)

## Post-Deployment Steps

### For Public Certificates

1. Wait for certificate validation:
   ```bash
   kubectl get certificate public-cert -n demo-app -w
   ```

2. Check external-dns logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns
   ```

3. Get the load balancer endpoint:
   ```bash
   kubectl get service hello-world-nlb -n demo-app
   ```

4. Test the application:
   ```bash
   curl -k https://your-domain.com
   ```

### For Private Certificates

1. Wait for certificate creation:
   ```bash
   kubectl get certificate private-cert -n demo-app -w
   ```

2. Get the internal load balancer endpoint:
   ```bash
   kubectl get service hello-world-nlb-private -n demo-app
   ```

3. Test from within the VPC (requires Private CA trust):
   ```bash
   curl -k https://internal-load-balancer-dns-name
   ```

## Manual Configuration Required

After deployment, you'll need to update the certificate ARNs in the load balancer service annotations:

1. Get the certificate ARN:
   ```bash
   # For public certificates
   kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.certificateARN}'
   
   # For private certificates  
   kubectl get certificate private-cert -n demo-app -o jsonpath='{.status.certificateARN}'
   ```

2. Update the service annotation with the actual certificate ARN:
   ```bash
   kubectl patch service hello-world-nlb -n demo-app -p '{"metadata":{"annotations":{"service.beta.kubernetes.io/aws-load-balancer-ssl-cert":"ACTUAL_CERT_ARN"}}}'
   ```

## Troubleshooting

### Certificate Issues
- Check certificate status: `kubectl describe certificate -n demo-app`
- Verify ACM controller logs: `kubectl logs -n ack-system -l app.kubernetes.io/name=acm-chart`

### Load Balancer Issues
- Check AWS Load Balancer Controller logs: `kubectl logs -n aws-load-balancer-system -l app.kubernetes.io/name=aws-load-balancer-controller`
- Verify service annotations: `kubectl describe service -n demo-app`

### DNS Issues (Public Path)
- Check external-dns logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns`
- Verify Route53 records in AWS Console

## Security Considerations

- Public certificates are automatically trusted by browsers and clients
- Private certificates require distributing and trusting the Private CA root certificate
- Network Load Balancers provide Layer 4 load balancing with TLS termination
- Consider using Web Application Firewall (WAF) for additional security with Application Load Balancers

## Next Steps

After setting up TLS termination at the load balancer, you can:

1. **Add WAF protection** for web applications
2. **Implement end-to-end encryption** by also enabling TLS between the load balancer and pods
3. **Set up monitoring and alerting** for certificate expiration
4. **Configure custom domains** and SSL policies
