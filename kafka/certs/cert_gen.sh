#!/bin/bash

set -eo pipefail
set -x
# --- Configuration ---
PASSWORD="install123!"
NAMESPACE="kafka"
WORK_DIR="kafka-certs"
TEMP_POD_NAME="jks-generator-pod-$(date +%s)"
SOURCE_CERTS_SECRET="kafka-certificates"
#
# --- Script Start ---
echo "--- Starting Kafka Certificate Generation (with Client Certs) ---"
echo "Output directory: $WORK_DIR"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

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
    image: openjdk:26-slim
    # Run a long-running command to keep the pod alive
    command: ["sleep", "3600"]
    volumeMounts:
    - name: certs-volume
      mountPath: /mnt/certs
  volumes:
  - name: certs-volume
EOF

# 2. Wait for the pod to be in the 'Running' state
echo "2. Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/${TEMP_POD_NAME} --namespace ${NAMESPACE} --timeout=240s
echo "   Pod is ready."

# 3. Generate Certificate Authority (CA)

echo
echo "--- 1. Generating a PROPER Certificate Authority (CA) ---"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -genkeypair -alias caroot -keyalg RSA -keysize 2048 -validity 3650 \
  -dname 'CN=KafkaClusterRootCA' \
  -keystore ca.keystore.jks -storetype JKS \
  -storepass '$PASSWORD' -keypass '$PASSWORD' \
  -ext "BC=ca:true" \
  -ext 'KU=keyCertSign,crlSign'"

kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -exportcert -alias caroot -file ca.crt \
  -keystore ca.keystore.jks \
  -storepass '$PASSWORD'"

# --- 2. Create the Cluster Truststore ---
echo
echo "--- 2. Creating the Cluster Truststore ---"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias caroot -file ca.crt \
  -keystore kafka.truststore.jks -storetype JKS \
  -storepass '$PASSWORD' -noprompt"

# --- 3. Generate Controller Keystore and Certificate ---
echo
echo "--- 3. Generating Controller Keystore and Certificate ---"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -genkeypair -alias kafka-controller -keyalg RSA -keysize 2048 \
  -dname "CN=kafka-controller" \
  -keystore controller.keystore.jks -storetype JKS \
  -storepass '$PASSWORD' -keypass '$PASSWORD'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -certreq -alias kafka-controller -file controller.csr \
  -keystore controller.keystore.jks \
  -storepass '$PASSWORD'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -gencert -alias caroot -validity 365 -rfc \
  -keystore ca.keystore.jks -storepass "$PASSWORD" \
  -infile controller.csr -outfile controller-signed.crt \
  -ext \"SAN=DNS:*.kafka-controller-headless.${NAMESPACE}.svc.cluster.local,DNS:kafka-controller-headless.${NAMESPACE}.svc.cluster.local\""
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias caroot -file ca.crt \
  -keystore controller.keystore.jks \
  -storepass '$PASSWORD' -noprompt"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias kafka-controller -file controller-signed.crt \
  -keystore controller.keystore.jks \
  -storepass '$PASSWORD' -noprompt"

# --- 4. Generate Broker Keystore and Certificate ---
echo
echo "--- 4. Generating Broker Keystore and Certificate ---"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -genkeypair -alias kafka-broker -keyalg RSA -keysize 2048 \
  -dname "CN=kafka-broker" \
  -keystore broker.keystore.jks -storetype JKS \
  -storepass '$PASSWORD' -keypass '$PASSWORD'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -certreq -alias kafka-broker -file broker.csr \
  -keystore broker.keystore.jks \
  -storepass '$PASSWORD'"
# MODIFICATION: Add the kafka-bootstrap service DNS name to the SAN list
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -gencert -alias caroot -validity 365 -rfc \
  -keystore ca.keystore.jks -storepass "$PASSWORD" \
  -infile broker.csr -outfile broker-signed.crt \
  -ext 'SAN=DNS:*.kafka-headless.${NAMESPACE}.svc.cluster.local,DNS:kafka-headless.${NAMESPACE}.svc.cluster.local,DNS:kafka-bootstrap.${NAMESPACE}.svc.cluster.local'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias caroot -file ca.crt \
  -keystore broker.keystore.jks \
  -storepass '$PASSWORD' -noprompt"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias kafka-broker -file broker-signed.crt \
  -keystore broker.keystore.jks \
  -storepass '$PASSWORD' -noprompt"

# --- 5. Generate Client Keystore and Certificate ---
echo
echo "--- 5. Generating Client Keystore and Certificate ---"
# ... (This section is unchanged) ...
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -genkeypair -alias kafka-client -keyalg RSA -keysize 2048 \
  -dname "CN=kafka-client" \
  -keystore client.keystore.jks -storetype JKS \
  -storepass '$PASSWORD' -keypass '$PASSWORD'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -certreq -alias kafka-client -file client.csr \
  -keystore client.keystore.jks \
  -storepass '$PASSWORD'"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -gencert -alias caroot -validity 365 -rfc \
  -keystore ca.keystore.jks -storepass '$PASSWORD' \
  -infile client.csr -outfile client-signed.crt"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias caroot -file ca.crt \
  -keystore client.keystore.jks \
  -storepass '$PASSWORD' -noprompt"
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  sh -c "cd /mnt/certs && keytool -importcert -alias kafka-client -file client-signed.crt \
  -keystore client.keystore.jks \
  -storepass '$PASSWORD' -noprompt"

# exit 0

kubectl cp -n ${NAMESPACE} "${TEMP_POD_NAME}:/mnt/certs/controller.keystore.jks" "./controller.keystore.jks"
kubectl cp -n ${NAMESPACE} "${TEMP_POD_NAME}:/mnt/certs/broker.keystore.jks" "./broker.keystore.jks"
kubectl cp -n ${NAMESPACE} "${TEMP_POD_NAME}:/mnt/certs/client.keystore.jks" "./client.keystore.jks"
kubectl cp -n ${NAMESPACE} "${TEMP_POD_NAME}:/mnt/certs/kafka.truststore.jks" "./kafka.truststore.jks"

# kubectl delete pod ${TEMP_POD_NAME} --namespace ${NAMESPACE}
# rm *.jks
# --- 6. Generate Kubernetes Secret YAML files ---
# ... (This section is unchanged but will generate new secret data) ...
echo
echo "--- 6. Generating Kubernetes Secret YAML files ---"
# Controller Secret YAML
cat <<EOF > kafka-controller-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-controller-secrets
  namespace: ${NAMESPACE}
type: Opaque
data:
  controller.keystore.jks: $(base64 -w 0 controller.keystore.jks)
  controller.truststore.jks: $(base64 -w 0 kafka.truststore.jks)
EOF
echo "Created kafka-controller-secrets.yaml"
# Broker Secret YAML
cat <<EOF > kafka-broker-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-broker-secrets
  namespace: ${NAMESPACE}
type: Opaque
data:
  broker.keystore.jks: $(base64 -w 0 broker.keystore.jks)
  broker.truststore.jks: $(base64 -w 0 kafka.truststore.jks)
EOF
echo "Created kafka-broker-secrets.yaml"
# Client Secret YAML
cat <<EOF > kafka-client-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-client-secrets
  namespace: ${NAMESPACE}
type: Opaque
data:
  client.keystore.jks: $(base64 -w 0 client.keystore.jks)
  kafka.truststore.jks: $(base64 -w 0 kafka.truststore.jks)
EOF
echo "Created kafka-client-secrets.yaml"
echo
echo "--- Certificate generation complete! ---"
