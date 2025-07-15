#!/bin/bash
set -e

# This script will remove all Kafka components from the 'kafka' namespace,
# leaving only the Kubernetes Secrets intact for a fresh re-deployment.

NAMESPACE="kafka"
APP_LABEL="app=kafka"

echo "--- Tearing down Kafka cluster in namespace: ${NAMESPACE} ---"

# 1. Delete the StatefulSets. This will terminate the pods.
echo "Deleting StatefulSets..."
kubectl delete statefulset -n ${NAMESPACE} -l ${APP_LABEL}

# 2. Delete the Services (headless and bootstrap).
echo "Deleting Services..."
kubectl delete service -n ${NAMESPACE} -l ${APP_LABEL}

# 3. Delete the ConfigMaps.
echo "Deleting ConfigMaps..."
kubectl delete configmap -n ${NAMESPACE} -l ${APP_LABEL}

# 4. Delete the PersistentVolumeClaims.
# This is the most important step for a truly fresh start, as it releases the storage.
echo "Deleting PersistentVolumeClaims..."
kubectl delete pvc -n ${NAMESPACE} -l ${APP_LABEL}

echo ""
echo "--- Teardown complete. Verifying namespace state... ---"
echo "The only resources remaining should be your secrets."
kubectl get all -n ${NAMESPACE}
