#!/bin/bash

echo "=== Deploying Fixed IMS Components ==="

# Check if namespace exists
if ! kubectl get namespace ims >/dev/null 2>&1; then
    echo "Creating IMS namespace..."
    kubectl create namespace ims
fi

# Function to wait for pod to be ready
wait_for_pod() {
    local component=$1
    local namespace=$2
    echo "Waiting for $component to be ready..."
    kubectl wait --for=condition=Ready pod -l io.kompose.service=$component -n $namespace --timeout=300s
    if [ $? -eq 0 ]; then
        echo "✓ $component is ready"
    else
        echo "✗ $component failed to become ready"
        kubectl get pods -n $namespace -l io.kompose.service=$component
        kubectl logs -n $namespace -l io.kompose.service=$component --tail=20
        return 1
    fi
}

# Deploy HSS first (since SCSCF depends on it)
echo "=== Deploying HSS ==="
kubectl delete deployment hss -n ims 2>/dev/null || true
kubectl apply -f hss-deployment.yaml
wait_for_pod hss ims

# Deploy SCSCF
echo "=== Deploying SCSCF ==="
kubectl delete deployment scscf -n ims 2>/dev/null || true
kubectl apply -f scscf-deployment.yaml
wait_for_pod scscf ims

# Show final status
echo "=== Final Status ==="
kubectl get pods -n ims
kubectl get svc -n ims

echo "=== Checking connectivity ==="
HSS_POD=$(kubectl get pods -n ims -l io.kompose.service=hss -o jsonpath='{.items[0].metadata.name}')
SCSCF_POD=$(kubectl get pods -n ims -l io.kompose.service=scscf -o jsonpath='{.items[0].metadata.name}')

echo "HSS Pod: $HSS_POD"
echo "SCSCF Pod: $SCSCF_POD"

# Test HSS listening on 3868
echo "Testing HSS Diameter port..."
kubectl exec $HSS_POD -n ims -- netstat -tlnp | grep 3868 && echo "✓ HSS listening on 3868" || echo "✗ HSS not listening on 3868"

# Test SCSCF listening on 6060
echo "Testing SCSCF Diameter port..."
kubectl exec $SCSCF_POD -n ims -- netstat -tlnp | grep 6060 && echo "✓ SCSCF listening on 6060" || echo "✗ SCSCF not listening on 6060"

# Test connectivity between components
echo "Testing SCSCF -> HSS connectivity..."
kubectl exec $SCSCF_POD -n ims -- timeout 5 bash -c '</dev/tcp/hss.ims.svc.cluster.local/3868' && echo "✓ SCSCF can connect to HSS" || echo "✗ SCSCF cannot connect to HSS"

echo "Testing HSS -> SCSCF connectivity..."
kubectl exec $HSS_POD -n ims -- timeout 5 bash -c '</dev/tcp/scscf.ims.svc.cluster.local/6060' && echo "✓ HSS can connect to SCSCF" || echo "✗ HSS cannot connect to SCSCF"

echo "=== Deployment completed ==="
echo ""
echo "To monitor logs:"
echo "kubectl logs $HSS_POD -n ims -f"
echo "kubectl logs $SCSCF_POD -n ims -f"
echo ""
echo "To check Diameter connection:"
echo "kubectl exec $SCSCF_POD -n ims -- cat /etc/kamailio_scscf/scscf.xml"
