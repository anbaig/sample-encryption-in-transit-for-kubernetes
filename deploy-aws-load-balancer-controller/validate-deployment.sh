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

echo "=== Validating Deployment ==="

# Check if namespaces exist
echo "Checking namespaces..."
kubectl get namespace aws-load-balancer-system ack-system demo-app

# Check controllers
echo "Checking AWS Load Balancer Controller..."
kubectl get deployment -n aws-load-balancer-system aws-load-balancer-controller

echo "Checking ACM Controller..."
kubectl get deployment -n ack-system

echo "Checking external-dns..."
kubectl get deployment -n kube-system external-dns

# Check application
echo "Checking hello world application..."
kubectl get deployment,service -n demo-app

# Check certificate
if [[ "$CERT_TYPE" == "public" ]]; then
  echo "Checking public certificate..."
  kubectl get certificate public-cert -n demo-app
  kubectl describe certificate public-cert -n demo-app
else
  echo "Checking private certificate..."
  kubectl get certificate private-cert -n demo-app
  kubectl describe certificate private-cert -n demo-app
fi

echo "=== Validation Complete ==="
