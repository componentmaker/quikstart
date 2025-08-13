#!/bin/bash

# Script to tear down the Elasticsearch cluster within the 'elastic' namespace.
# It deletes all deployed resources but leaves the 'elastic' namespace itself.

NAMESPACE="elastic"

echo "Starting teardown of Elasticsearch cluster in namespace: $NAMESPACE"
echo "------------------------------------------------------------------"

echo "1. Deleting Pod Disruption Budget (PDB)..."
kubectl delete pdb elasticsearch-pdb -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   PDB deleted successfully (or not found)."
else
    echo "   Error deleting PDB. Continuing anyway."
fi

echo "2. Deleting Services..."
kubectl delete svc elasticsearch-client es-svc -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   Services deleted successfully (or not found)."
else
    echo "   Error deleting Services. Continuing anyway."
fi

echo "3. Deleting StatefulSet..."
kubectl delete statefulset elasticsearch -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   StatefulSet deleted successfully (or not found)."
else
    echo "   Error deleting StatefulSet. Continuing anyway."
fi

echo "4. Waiting for Elasticsearch pods to terminate..."
# Use a timeout to prevent indefinite waiting
kubectl wait --for=delete pod -l app=elasticsearch -n "$NAMESPACE" --timeout=120s 2>/dev/null
if [ $? -eq 0 ]; then
    echo "   Elasticsearch pods terminated."
else
    echo "   Timeout waiting for pods to terminate, or no pods found. Continuing."
fi

echo "5. Deleting Persistent Volume Claims (PVCs)..."
# PVCs are created by StatefulSets and need to be explicitly deleted to release PVs
kubectl delete pvc -l app=elasticsearch -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   PVCs deleted successfully (or not found)."
else
    echo "   Error deleting PVCs. Continuing anyway."
fi

echo "6. Deleting ConfigMaps..."
kubectl delete configmap elasticsearch-config -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   ConfigMap deleted successfully (or not found)."
else
    echo "   Error deleting ConfigMap. Continuing anyway."
fi

echo "7. Deleting Secrets..."
kubectl delete secret elastic-certificates elastic-credentials -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   Secrets deleted successfully (or not found)."
else
    echo "   Error deleting Secrets. Continuing anyway."
fi

echo "------------------------------------------------------------------"
echo "Elasticsearch cluster teardown complete in namespace: $NAMESPACE."
echo "The namespace '$NAMESPACE' itself has NOT been deleted."
echo "You may want to manually check for any remaining Persistent Volumes (PVs) if your StorageClass does not automatically reclaim them:"
echo "  kubectl get pv | grep elastic"
echo "If any PVs are stuck in 'Released' or 'Failed' state, you might need to delete them manually:"
echo "  kubectl delete pv <pv-name>"
