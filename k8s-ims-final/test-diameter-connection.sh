#!/bin/bash

echo "=== Testing Diameter Connection Between HSS and SCSCF ==="

# Get pod names
HSS_POD=$(kubectl get pods -n ims -l io.kompose.service=hss -o jsonpath='{.items[0].metadata.name}')
SCSCF_POD=$(kubectl get pods -n ims -l io.kompose.service=scscf -o jsonpath='{.items[0].metadata.name}')

echo "HSS Pod: $HSS_POD"
echo "SCSCF Pod: $SCSCF_POD"

# Test 1: Check if pods are running
echo ""
echo "=== Pod Status ==="
kubectl get pods -n ims | grep -E "(hss|scscf)"

# Test 2: Check listening ports
echo ""
echo "=== Port Status ==="
echo "HSS Diameter port (3868):"
kubectl exec $HSS_POD -n ims -- netstat -tlnp | grep 3868 || echo "Not listening"

echo "SCSCF Diameter port (6060):"
kubectl exec $SCSCF_POD -n ims -- netstat -tlnp | grep 6060 || echo "Not listening"

# Test 3: DNS resolution
echo ""
echo "=== DNS Resolution ==="
echo "SCSCF resolving HSS:"
kubectl exec $SCSCF_POD -n ims -- nslookup hss.ims.svc.cluster.local

echo "HSS resolving SCSCF:"
kubectl exec $HSS_POD -n ims -- nslookup scscf.ims.svc.cluster.local

# Test 4: Network connectivity
echo ""
echo "=== Network Connectivity ==="
echo "SCSCF -> HSS (3868):"
kubectl exec $SCSCF_POD -n ims -- timeout 5 bash -c '</dev/tcp/hss.ims.svc.cluster.local/3868' && echo "✓ Connected" || echo "✗ Failed"

echo "HSS -> SCSCF (6060):"
kubectl exec $HSS_POD -n ims -- timeout 5 bash -c '</dev/tcp/scscf.ims.svc.cluster.local/6060' && echo "✓ Connected" || echo "✗ Failed"

# Test 5: Check configurations
echo ""
echo "=== Configuration Check ==="
echo "SCSCF Diameter configuration:"
kubectl exec $SCSCF_POD -n ims -- cat /etc/kamailio_scscf/scscf.xml 2>/dev/null | grep -E "FQDN|port|bind" || echo "Configuration file not found or has issues"

echo "HSS Diameter peers:"
kubectl exec $HSS_POD -n ims -- grep -A1 "ConnectPeer.*scscf" /open5gs/install/etc/freeDiameter/hss.conf

# Test 6: Check recent logs for Diameter messages
echo ""
echo "=== Recent Diameter Logs ==="
echo "SCSCF logs (last 10 lines with Diameter/HSS keywords):"
kubectl logs $SCSCF_POD -n ims --tail=50 | grep -i "diameter\|hss\|peer" | tail -10

echo "HSS logs (last 10 lines with Diameter/SCSCF keywords):"
kubectl logs $HSS_POD -n ims --tail=50 | grep -i "diameter\|scscf\|peer" | tail -10

echo ""
echo "=== Test Complete ==="
echo ""
echo "If connection is successful, you should see:"
echo "- Both pods listening on their respective Diameter ports"
echo "- Successful TCP connections between pods"
echo "- Diameter peer establishment messages in logs"
