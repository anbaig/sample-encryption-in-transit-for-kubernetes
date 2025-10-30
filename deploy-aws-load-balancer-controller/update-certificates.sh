#!/bin/bash
set -euo pipefail

CERT_TYPE="public"

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --cert-type)
      CERT_TYPE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "=== Updating Certificate ARNs ==="

if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Getting public certificate ARN..."
  CERT_ARN=$(kubectl get certificate public-cert -n demo-app -o jsonpath='{.status.certificateARN}')
  SERVICE_NAME="hello-world-nlb"
else
  echo "Getting private certificate ARN..."
  CERT_ARN=$(kubectl get certificate private-cert -n demo-app -o jsonpath='{.status.certificateARN}')
  SERVICE_NAME="hello-world-nlb-private"
fi

if [[ -z "$CERT_ARN" ]]; then
  echo "Error: Certificate ARN not found. Make sure the certificate is issued."
  exit 1
fi

echo "Certificate ARN: $CERT_ARN"
echo "Updating service $SERVICE_NAME..."

kubectl patch service $SERVICE_NAME -n demo-app -p "{\"metadata\":{\"annotations\":{\"service.beta.kubernetes.io/aws-load-balancer-ssl-cert\":\"$CERT_ARN\"}}}"

echo "Certificate ARN updated successfully!"
echo "The load balancer will be updated with the new certificate."
