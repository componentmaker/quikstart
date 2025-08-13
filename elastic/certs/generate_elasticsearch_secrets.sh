#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
NAMESPACE="elastic"
ES_VERSION="8.18.4"
ES_POD_NAMES=("elasticsearch-0" "elasticsearch-1" "elasticsearch-2")
ES_SVC_DNS="es-svc.${NAMESPACE}.svc.cluster.local"
# The name of your Elasticsearch StatefulSet. This is needed for the final instruction message.
ES_STATEFULSET_NAME="elasticsearch"

# --- Main execution ---
echo "Starting certificate management process for Elasticsearch..."
echo "--------------------------------------------------------------------------------"

# Determine if we are performing an initial setup or a certificate rotation
ROTATION_MODE="false"
if kubectl get secret elastic-certificates -n "$NAMESPACE" &>/dev/null; then
    ROTATION_MODE="true"
    echo "INFO: Existing 'elastic-certificates' secret found. Running in ROTATION MODE."
    echo "INFO: New certificates will be generated and bundled with the old CA for a seamless transition."
else
    echo "INFO: No existing 'elastic-certificates' secret found. Running in INITIAL SETUP MODE."
fi
echo "--------------------------------------------------------------------------------"


# 1. Create the Kubernetes Namespace if it doesn't exist
echo "1. Ensuring namespace '$NAMESPACE' exists..."
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
echo "   Namespace '$NAMESPACE' is ready."

# 2. Define and launch the temporary cert generator pod
echo "2. Creating temporary certificate generator pod..."
cat <<EOF > 01-security-setup-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: es-cert-generator
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: es-cert-generator
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
    command: ["sleep", "3600"] # Keep the pod running
    volumeMounts:
    - name: certs-volume
      mountPath: /usr/share/elasticsearch/certs
  volumes:
  - name: certs-volume
    emptyDir: {} # Temporary volume for certs
  restartPolicy: Never
EOF

kubectl apply -f 01-security-setup-pod.yaml -n "$NAMESPACE"
echo "   Waiting for es-cert-generator pod to be running..."
kubectl wait --for=condition=ready pod/es-cert-generator -n "$NAMESPACE" --timeout=300s
echo "   es-cert-generator pod is running."

# 3. Generate a new CA certificate inside the pod
echo "3. Generating new CA certificate..."
kubectl exec -it es-cert-generator -n "$NAMESPACE" -- bin/elasticsearch-certutil ca --pem --out /usr/share/elasticsearch/certs/ca.zip
kubectl exec -it es-cert-generator -n "$NAMESPACE" -- unzip -o /usr/share/elasticsearch/certs/ca.zip -d /usr/share/elasticsearch/certs/
echo "   New CA certificate generated."

# 4. Generate new Node Certificates inside the pod
echo "4. Generating new node certificates..."
DNS_SANS=$(IFS=,; echo "${ES_POD_NAMES[*]}")
DNS_SANS="${DNS_SANS},${ES_SVC_DNS},localhost"

kubectl exec -it es-cert-generator -n "$NAMESPACE" -- bin/elasticsearch-certutil cert \
  --name elasticsearch-node \
  --dns "${DNS_SANS}" \
  --ip 127.0.0.1 \
  --ca-cert /usr/share/elasticsearch/certs/ca/ca.crt \
  --ca-key /usr/share/elasticsearch/certs/ca/ca.key \
  --pem \
  --out /usr/share/elasticsearch/certs/certs.zip

kubectl exec -it es-cert-generator -n "$NAMESPACE" -- unzip -o /usr/share/elasticsearch/certs/certs.zip -d /usr/share/elasticsearch/certs/
echo "   New node certificates generated."

# 5. Copy certificates locally and handle rotation logic
echo "5. Copying certificates locally and preparing secrets..."
mkdir -p ./es-certs
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/ca/ca.crt" ./es-certs/ca.crt
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/ca/ca.key" ./es-certs/ca.key
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/elasticsearch-node/elasticsearch-node.crt" ./es-certs/node.crt
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/elasticsearch-node/elasticsearch-node.key" ./es-certs/node.key
echo "   New certificates copied from pod."

# If in rotation mode, create a CA bundle. Otherwise, just use the new CA.
if [ "$ROTATION_MODE" = "true" ]; then
    echo "   ROTATION MODE: Fetching old CA to create a trust bundle..."
    kubectl get secret elastic-certificates -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' | base64 --decode > ./es-certs/old-ca.crt
    cat ./es-certs/ca.crt ./es-certs/old-ca.crt > ./es-certs/ca-bundle.crt
    export CA_CRT_B64=$(base64 -w 0 ./es-certs/ca-bundle.crt)
    echo "   CA bundle created by combining new and old CAs."
else
    export CA_CRT_B64=$(base64 -w 0 ./es-certs/ca.crt)
fi

export CA_KEY_B64=$(base64 -w 0 ./es-certs/ca.key) # Always use the new CA key
export NODE_CRT_B64=$(base64 -w 0 ./es-certs/node.crt)
export NODE_KEY_B64=$(base64 -w 0 ./es-certs/node.key)
echo "   Certificates encoded for secret creation."

# 6. Get the elastic superuser password (only if the credential secret doesn't already exist)
if ! kubectl get secret elastic-credentials -n "$NAMESPACE" &>/dev/null; then
    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo "--------------------------------------------------------------------------------"
        echo "ELASTIC_PASSWORD environment variable not set."
        read -sp "Please enter a password for the 'elastic' superuser: " ELASTIC_PASSWORD
        echo
        if [ -z "$ELASTIC_PASSWORD" ]; then
            echo "Password cannot be empty. Aborting."
            exit 1
        fi
    fi
    # Create the credentials secret immediately
    kubectl create secret generic elastic-credentials -n "$NAMESPACE" --from-literal=elastic-password="$ELASTIC_PASSWORD"
    echo "   'elastic-credentials' secret has been created."
    echo "--------------------------------------------------------------------------------"
fi

# 7. Define the certificate secret YAML from a template
echo "6. Generating 02-certificates-secret.yaml..."
cat <<EOF > 02-certificates-secret.yaml.template
apiVersion: v1
kind: Secret
metadata:
  name: elastic-certificates
  namespace: ${NAMESPACE}
type: Opaque
data:
  ca.crt: |
    \${CA_CRT_B64}
  node.crt: |
    \${NODE_CRT_B64}
  node.key: |
    \${NODE_KEY_B64}
EOF

# Note: We do not include the ca.key in the final secret. It is not needed by Elasticsearch for TLS and keeping it out is more secure.
envsubst < 02-certificates-secret.yaml.template > 02-certificates-secret.yaml
echo "   02-certificates-secret.yaml generated."

# 8. Apply the secrets
echo "7. Applying Kubernetes Secrets..."
kubectl apply -f 02-certificates-secret.yaml -n "$NAMESPACE"
echo "   Secrets applied successfully."

# 9. Clean up temporary files and pod
echo "8. Cleaning up temporary files and pod..."
kubectl delete pod es-cert-generator -n "$NAMESPACE" --ignore-not-found=true
rm 01-security-setup-pod.yaml
rm 02-certificates-secret.yaml.template
# rm -rf ./es-certs # Keep certs for debugging or backup
echo "   Cleanup complete."

# --- Final Instructions ---
echo "--------------------------------------------------------------------------------"
if [ "$ROTATION_MODE" = "true" ]; then
    echo "✅ CERTIFICATE ROTATION COMPLETE ✅"
    echo ""
    echo "The 'elastic-certificates' secret has been updated with the new certificates."
    echo "To apply them to your cluster without downtime, perform a rolling restart:"
    echo ""
    echo "  kubectl rollout restart statefulset/${ES_STATEFULSET_NAME} -n ${NAMESPACE}"
    echo ""
    echo "After the rollout is complete, you can run this script again to finalize"
    echo "the rotation, which will remove the old CA from the trust bundle."
else
    echo "✅ INITIAL SETUP COMPLETE ✅"
    echo "You can now proceed with deploying your Elasticsearch cluster."
fi
echo "--------------------------------------------------------------------------------"
