#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# --- Configuration ---
# Set the Kubernetes namespace where the resources will be created and found.
NAMESPACE="elastic"
SECRET_NAMESPACE="pegabackingservices"

# The name of the secret containing the source certificates (ca.crt, node.crt, node.key).
SOURCE_CERTS_SECRET="elastic-certificates"
# The name for the Kubernetes Secret resource that will be generated.
OUTPUT_SECRET_NAME="elastic-keystore-secret"
# The output filename for the generated Kubernetes manifest.
OUTPUT_YAML_FILE="03-keystore-secret.yaml"
# The name for the temporary pod that will perform the generation.
TEMP_POD_NAME="jks-generator-pod-$(date +%s)"
# The password for the keystore.
KEYSTORE_PASSWORD="install123!"
# --- End of Configuration ---

# Define temporary filenames for clarity
P12_FILE="node.p12"
JKS_FILE="node.jks"
LOCAL_JKS_FILE="node.jks" # Local temporary copy

echo "--- Starting JKS Generation using a Temporary Kubernetes Pod ---"

# 1. Launch a temporary pod with OpenJDK to run keytool
echo "1. Launching temporary pod '${TEMP_POD_NAME}' in namespace '${NAMESPACE}'..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEMP_POD_NAME}
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: jks-generator
    image: openjdk:8-jdk-slim
    # Run a long-running command to keep the pod alive
    command: ["sleep", "3600"]
    volumeMounts:
    - name: certs-volume
      mountPath: /mnt/certs
  volumes:
  - name: certs-volume
    secret:
      secretName: ${SOURCE_CERTS_SECRET}
EOF

# 2. Wait for the pod to be in the 'Running' state
echo "2. Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/${TEMP_POD_NAME} --namespace ${NAMESPACE} --timeout=240s
echo "   Pod is ready."

# 3. Execute the commands inside the pod to generate the JKS file
echo "3. Executing certificate conversion inside the pod..."

# Create PKCS12 filekubectl rollout status statefulset/$STATEFULSET_NAME -n $NAMESPACE
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "openssl pkcs12 -export \
-in /mnt/certs/node.crt \
-inkey /mnt/certs/node.key \
-out /tmp/${P12_FILE} \
-name elastic-node \
-certfile /mnt/certs/ca.crt \
-passout 'pass:${KEYSTORE_PASSWORD}'"

# Convert PKCS12 to JKS
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "keytool -importkeystore \
-deststorepass "${KEYSTORE_PASSWORD}" \
-destkeystore /tmp/${JKS_FILE} \
-srckeystore /tmp/${P12_FILE} \
-srcstoretype PKCS12 \
-srcstorepass "${KEYSTORE_PASSWORD}" \
-noprompt"
echo "   JKS file generated inside the pod."

# 4. Copy the generated JKS file from the pod to the local machine
echo "4. Copying generated JKS file from pod..."
kubectl cp "${NAMESPACE}/${TEMP_POD_NAME}:/tmp/${JKS_FILE}" "${LOCAL_JKS_FILE}"
echo "   JKS file copied locally."

# 5. Base64 encode the local JKS file for the Kubernetes Secret
echo "5. Base64 encoding the JKS file..."
# The '-w 0' flag prevents line wrapping, which is required for Kubernetes secrets.
JKS_B64=$(base64 -w 0 "${LOCAL_JKS_FILE}")
echo "   Encoding complete."

# 6. Generate the Kubernetes Secret YAML file
echo "6. Generating Kubernetes Secret YAML file: ${OUTPUT_YAML_FILE}..."
cat <<EOF > "${OUTPUT_YAML_FILE}"
apiVersion: v1
kind: Secret
metadata:
  name: ${OUTPUT_SECRET_NAME}
type: Opaque
# 'data' field is for base64 encoded binary data
data:
  node.jks: ${JKS_B64}
# 'stringData' is for plain-text strings. Kubernetes handles the encoding.
stringData:
  password: "${KEYSTORE_PASSWORD}"
EOF
echo "   YAML file generated."

# 7. Clean up the temporary pod and local files
echo "7. Cleaning up temporary resources..."
kubectl delete pod ${TEMP_POD_NAME} --namespace ${NAMESPACE}
rm "${LOCAL_JKS_FILE}"
echo "   Cleanup complete."

# 8. Apply the secrets
echo "7. Applying Kubernetes Secrets..."
kubectl apply -f "${OUTPUT_YAML_FILE}" -n "$SECRET_NAMESPACE"
echo "   Secrets applied successfully."

echo "---"
echo "✅ Success! The Kubernetes Secret manifest has been created."
echo
echo "   File created: ${OUTPUT_YAML_FILE}"
echo "   Secret Name:  ${OUTPUT_SECRET_NAME}"
echo "   Namespace:    ${NAMESPACE}"
echo
echo "To apply this secret to your cluster, run the following command:"
echo "   kubectl apply -f ${OUTPUT_YAML_FILE}"
echo "---"
