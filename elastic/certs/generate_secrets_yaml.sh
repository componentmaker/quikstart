#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

NAMESPACE="elastic"
ES_VERSION="8.15.5"
ES_POD_NAMES=("elasticsearch-0" "elasticsearch-1" "elasticsearch-2")
ES_SVC_DNS="es-svc.${NAMESPACE}.svc.cluster.local"

echo "Starting certificate generation and Kubernetes Secret creation for Elasticsearch..."
echo "--------------------------------------------------------------------------------"

# 1. Create the Kubernetes Namespace if it doesn't exist
echo "1. Ensuring namespace '$NAMESPACE' exists..."
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
echo "   Namespace '$NAMESPACE' is ready."

# 2. Define the temporary cert generator pod YAML
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
    command: ["sleep", "3600"] # Keep the pod running for manual operations
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

# 3. Generate CA and Node Certificates inside the pod
echo "3. Generating CA certificate..."
kubectl exec -it es-cert-generator -n "$NAMESPACE" -- bin/elasticsearch-certutil ca --pem --out /usr/share/elasticsearch/certs/ca.zip
kubectl exec -it es-cert-generator -n "$NAMESPACE" -- unzip -o /usr/share/elasticsearch/certs/ca.zip -d /usr/share/elasticsearch/certs/
echo "   CA certificate generated."

echo "4. Generating node certificates with correct DNS SANs..."
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
echo "   Node certificates generated."

# 5. Copy certificates locally and base64 encode
echo "5. Copying certificates locally and encoding for secrets..."
mkdir -p ./es-certs

kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/ca/ca.crt" ./es-certs/ca.crt
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/ca/ca.key" ./es-certs/ca.key
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/elasticsearch-node/elasticsearch-node.crt" ./es-certs/node.crt
kubectl cp "${NAMESPACE}/es-cert-generator:/usr/share/elasticsearch/certs/elasticsearch-node/elasticsearch-node.key" ./es-certs/node.key

export CA_CRT_B64=$(base64 -w 0 ./es-certs/ca.crt)
export CA_KEY_B64=$(base64 -w 0 ./es-certs/ca.key)
export NODE_CRT_B64=$(base64 -w 0 ./es-certs/node.crt)
export NODE_KEY_B64=$(base64 -w 0 ./es-certs/node.key)
echo "   Certificates copied and base64 encoded."

# 6. Get the elastic superuser password
if [ -z "$ELASTIC_PASSWORD" ]; then
    echo "--------------------------------------------------------------------------------"
    echo "ELASTIC_PASSWORD environment variable not set."
    read -sp "Please enter a password for the 'elastic' superuser: " ELASTIC_PASSWORD
    echo
    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo "Password cannot be empty. Aborting."
        exit 1
    fi
    echo "Password has been set."
    echo "--------------------------------------------------------------------------------"
fi

# 6. Define the secrets template
echo "6. Generating 02-secrets.yaml from template..."
cat <<EOF > 02-secrets.yaml.template
apiVersion: v1
kind: Secret
metadata:
  name: elastic-certificates
  namespace: ${NAMESPACE}
type: Opaque
data:
  ca.crt: |
    \${CA_CRT_B64}
  ca.key: |
    \${CA_KEY_B64}
  node.crt: |
    \${NODE_CRT_B64}
  node.key: |
    \${NODE_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: elastic-credentials
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  elastic-password: "${ELASTIC_PASSWORD}"
EOF

envsubst < 02-secrets.yaml.template > 02-secrets.yaml
echo "   02-secrets.yaml generated. "

# 7. Manual step for user to set passwor# 8. Apply the secrets
echo "7. Applying Kubernetes Secrets..."
kubectl apply -f 02-secrets.yaml -n "$NAMESPACE"
echo "   Secrets applied successfully."

# 9. Clean up temporary files and pod
echo "8. Cleaning up temporary files and pod..."
kubectl delete pod es-cert-generator -n "$NAMESPACE" --ignore-not-found=true
rm 01-security-setup-pod.yaml
rm 02-secrets.yaml.template
rm -rf ./es-certs
echo "   Cleanup complete."

echo "--------------------------------------------------------------------------------"
echo "Certificate generation and Secret creation process finished."
echo "You can now proceed with deploying the rest of your Elasticsearch cluster."
echo "--------------------------------------------------------------------------------"
