# Concatenated File Contents

## File: `./install/post_deployment.sh`

```sh
#!/bin/bash

# --- Configuration ---
NAMESPACE="elastic"
CONFIGMAP_NAME="elasticsearch-config"
STATEFULSET_NAME="elasticsearch" # IMPORTANT: Change this to your StatefulSet's name
KEY_TO_MODIFY="elasticsearch.yml"
LINE_TO_REMOVE="cluster.initial_master_nodes"
# --- End of Configuration ---

# Step 1: Get the entire original ConfigMap YAML.
echo "Fetching current ConfigMap '$CONFIGMAP_NAME'..."
original_cm_yaml=$(kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get ConfigMap. Aborting."
    exit 1
fi

# Step 2: Extract the raw string content of the 'elasticsearch.yml' key.
# We use yq for this to handle YAML structure correctly.
es_yml_content=$(echo "$original_cm_yaml" | yq e '.data["'${KEY_TO_MODIFY}'"]')

# Step 3: Modify the extracted string content using sed.
modified_es_yml_content=$(echo "$es_yml_content" | sed "/${LINE_TO_REMOVE}/d")

# Step 4: Use yq to create the final YAML, replacing the old content with the modified content.
# We export the variable so yq's 'strenv' can read it, preserving all special characters and newlines.
export MODIFIED_CONTENT_VAR="$modified_es_yml_content"
final_cm_yaml=$(echo "$original_cm_yaml" | yq e '.data["'${KEY_TO_MODIFY}'"] = strenv(MODIFIED_CONTENT_VAR)')

# Step 5: Apply the final, corrected YAML to the cluster.
echo "Applying patched ConfigMap..."
echo "$final_cm_yaml" | kubectl apply -f -
if [ $? -ne 0 ]; then
    echo "Error: Failed to apply the patched ConfigMap. Aborting."
    exit 1
fi

echo "ConfigMap patched successfully."
echo "---"

# Step 6: Trigger the rolling restart of the StatefulSet.
echo "Initiating a rolling restart for StatefulSet '$STATEFULSET_NAME'..."
kubectl rollout restart statefulset/"$STATEFULSET_NAME" -n "$NAMESPACE"

echo "StatefulSet restart initiated. Monitor the pod rollout status with:"
echo "kubectl rollout status statefulset/$STATEFULSET_NAME -n $NAMESPACE --watch"
```

---

## File: `./install/tear_down.sh`

```sh
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

echo "8. Checking for and deleting Kibana resources (if deployed)..."
kubectl delete deployment kibana -n "$NAMESPACE" --ignore-not-found=true
kubectl delete svc kibana-svc -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   Kibana resources deleted successfully (or not found)."
else
    echo "   Error deleting Kibana resources. Continuing anyway."
fi

echo "------------------------------------------------------------------"
echo "Elasticsearch cluster teardown complete in namespace: $NAMESPACE."
echo "The namespace '$NAMESPACE' itself has NOT been deleted."
echo "You may want to manually check for any remaining Persistent Volumes (PVs) if your StorageClass does not automatically reclaim them:"
echo "  kubectl get pv | grep elastic"
echo "If any PVs are stuck in 'Released' or 'Failed' state, you might need to delete them manually:"
echo "  kubectl delete pv <pv-name>"
```

---

## File: `./install/04-statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  podManagementPolicy: "Parallel"
  serviceName: es-svc
  replicas: 3 # Recommended 3 master-eligible nodes for production
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      # Optional: Node Selector or Tolerations for specific nodes
      # nodeSelector:
      #   node-role.kubernetes.io/data: "true"

      # Pod Anti-Affinity for High Availability
      securityContext:
        fsGroup: 1000        # Ensure the volume's group ID is 1000
        # runAsUser: 1000      # Run containers as user ID 1000 (Elasticsearch user)
        # runAsGroup: 1000     # Run containers as group ID 1000     
        # fsGroupChangePolicy: "Always"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: elasticsearch
              topologyKey: kubernetes.io/hostname # Spread pods across different nodes
      
      initContainers:
      - name: sysctl
        image: busybox:1.36.1 # Use a recent busybox image
        command: ["sh", "-c", "sysctl -w vm.max_map_count=262144"]
        securityContext:
          privileged: true # Required for sysctl
          runAsUser: 0           # Run init container as root to ensure sysctl works
          runAsGroup: 0
      # - name: setup-keystore
      #   image: docker.elastic.co/elasticsearch/elasticsearch:8.15.5
      #   command:
      #     - /bin/bash
      #     - -c
      #     - |
      #       set -e
      #       echo "Setting up Elasticsearch Keystore..."
      #       # Create an empty keystore if it doesn't exist
      #       if [ ! -f config/elasticsearch.keystore ]; then
      #         echo "Creating new keystore..."
      #         bin/elasticsearch-keystore create
      #       fi
      #       # Add the bootstrap password from the secret. The '|| true' prevents failure if the key already exists on restart.
      #       echo "$ELASTIC_PASSWORD" | bin/elasticsearch-keystore add -x 'bootstrap.password' || true
      #       echo "Keystore setup complete."
        # env:
        #   - name: ELASTIC_PASSWORD
        #     valueFrom:
        #       secretKeyRef:
        #         name: elastic-credentials
        #         key: elastic-password
        # volumeMounts:
        # # Note: We only need to mount the 'data' volume here, as the keystore
        # # is written to the persistent data directory. The main container will
        # # then have access to it.
        # - name: data
        #   mountPath: /usr/share/elasticsearch/data
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:8.18.4
        env:
          - name: ELASTIC_PASSWORD
            valueFrom:
              secretKeyRef:
                name: elastic-credentials
                key: elastic-password          
          - name: NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: CLUSTER_NAME
            value: elasticsearch-cluster
          # - name: DISCOVERY_SERVICE
          #   value: es-svc.elastic.svc.cluster.local
          - name: ES_JAVA_OPTS
            # Adjust based on your node memory. Typically 50% of allocated memory, but not more than 30.5GB.
            # Example: for 4GiB memory limit, set Xms/Xmx to 2g
            value: "-Xms2g -Xmx2g" # Example: 2GB heap. Adjust for your actual needs.
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          # Optional: Add any other environment variables for Elasticsearch configuration
          # - name: xpack.monitoring.collection.enabled
          #   value: "true"
          # - name: CLUSTER_INITIAL_MASTER_NODES # <<< ADD THIS ENVIRONMENT VARIABLE
          #   value: "elasticsearch-0,elasticsearch-1,elasticsearch-2" 
        resources:
          requests:
            memory: 4Gi # Request 4GB memory
            cpu: 1 # Request 1 CPU core
          limits:
            memory: 4Gi # Limit to 4GB memory
            cpu: 2 # Limit to 2 CPU cores (burst capacity)
        
        ports:
        - containerPort: 9200 # HTTP
          name: http
        - containerPort: 9300 # Transport
          name: transport
        
        volumeMounts:
        - name: config
          mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
          subPath: elasticsearch.yml
        - name: config
          mountPath: /usr/share/elasticsearch/config/log4j2.properties
          subPath: log4j2.properties
        - name: certs
          mountPath: /usr/share/elasticsearch/config/certs
        - name: data
          mountPath: /usr/share/elasticsearch/data
        
        # securityContext:
        #   allowPrivilegeEscalation: false # Prevent processes from gaining more privileges
        #   readOnlyRootFilesystem: true    # Make root filesystem read-only (all writes to mounted volumes)
        #   runAsNonRoot: true              # Ensure container runs as non-root user (UID 1000)
        # Health Checks
        startupProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS # Use HTTPS for secure cluster
          #   path: /_cluster/health?wait_for_status=green&timeout=1s
            port: 9200
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 60 # Allow 5 minutes for startup
        livenessProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS
          #   path: /_cluster/health?timeout=1s
            port: 9200
          initialDelaySeconds: 30 # Give some time after startup
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS
          #   path: /_cluster/health?timeout=1s
            port: 9200
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 5
          failureThreshold: 3

      volumes:
      - name: config
        configMap:
          name: elasticsearch-config
      - name: certs
        secret:
          secretName: elastic-certificates
  
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ] # Must be ReadWriteOnce for StatefulSets
      resources:
        requests:
          storage: 50Gi # Adjust storage size as needed for production data
      # storageClassName: your-custom-storage-class # Uncomment and set if not using default
```

---

## File: `./install/07-pod-disruption-budget.yaml`

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: elasticsearch-pdb
  namespace: elastic
spec:
  minAvailable: 2 # Allow at most 1 node to be unavailable at a time (for a 3 node cluster)
  selector:
    matchLabels:
      app: elasticsearch
```

---

## File: `./install/03-configmaps.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
  namespace: elastic
data:
  elasticsearch.yml: |
    cluster.name: elasticsearch-cluster
    node.name: ${POD_NAME}

    node.roles: [ master, data, ingest ]    
    
    network.host: 0.0.0.0
    http.port: 9200
    transport.port: 9300

    # Paths
    path.data: /usr/share/elasticsearch/data
    path.logs: /usr/share/elasticsearch/logs

    # Security (TLS)
    xpack.security.enabled: true
    xpack.security.http.ssl.enabled: true
    xpack.security.http.ssl.certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
    xpack.security.http.ssl.certificate: /usr/share/elasticsearch/config/certs/node.crt
    xpack.security.http.ssl.key: /usr/share/elasticsearch/config/certs/node.key
    xpack.security.transport.ssl.enabled: true
    xpack.security.transport.ssl.verification_mode: certificate
    # xpack.security.transport.ssl.verification_mode: none
    xpack.security.transport.ssl.certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
    xpack.security.transport.ssl.certificate: /usr/share/elasticsearch/config/certs/node.crt
    xpack.security.transport.ssl.key: /usr/share/elasticsearch/config/certs/node.key

    # Discovery
    discovery.seed_hosts: ["es-svc.elastic.svc.cluster.local"]
    cluster.initial_master_nodes: ["elasticsearch-0", "elasticsearch-1", "elasticsearch-2"] # Assuming 3 initial nodes

    # Heap size (adjust based on your node memory)
    # ES_JAVA_OPTS will override this, but good to have a default here too for clarity
    # ES will auto-detect up to 50% of available memory, or 32GB
    # For production, set ES_JAVA_OPTS correctly based on K8s limits
    # xpack.ml.enabled: false # Disable ML if not needed to save resources
    # xpack.security.enrollment.enabled: true # Enable for simplified setup with Kibana
    # xpack.security.http.ssl.client_authentication: optional # Optional for client auth
  log4j2.properties: |
    status = error
    name = elasticsearch-config
    appender.console.type = Console
    appender.console.name = console
    appender.console.layout.type = PatternLayout
    appender.console.layout.pattern = [%d{ISO8601}][%-5p][%-25c{1.}] %marker%m%n
    rootLogger.level = info 
    rootLogger.appenderRef.console.ref = console
```

---

## File: `./install/06-network-policy.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: elasticsearch-network-policy  # Same name, so it will replace the old one
  namespace: elastic
spec:
  # Apply this policy to all pods with the 'app=elasticsearch' label
  podSelector:
    matchLabels:
      app: elasticsearch
  policyTypes:
  - Ingress
  - Egress

  # Define rules for INCOMING traffic
  ingress:
  - from:
      # Allow traffic FROM other Elasticsearch pods
      - podSelector:
          matchLabels:
            app: elasticsearch
      # Allow traffic FROM any pod in the same 'elastic' namespace
      # This is useful for clients or other tools in the same namespace
      - namespaceSelector:
          matchLabels:
            # Use a standard label that is present on all namespaces by default
            kubernetes.io/metadata.name: elastic
  - from:
    - namespaceSelector:
        matchLabels:
          # This assumes your pegabackingservices namespace is labeled this way.
          # Check with 'kubectl get ns --show-labels'
          kubernetes.io/metadata.name: pegabackingservices
    ports:
    # On the following ports
    - protocol: TCP
      port: 9200  # for HTTP, clients, and probes
    - protocol: TCP
      port: 9300  # for inter-node transport/clustering

  # Define rules for OUTGOING traffic
  egress:
  # Allow pods to talk to each other
  - to:
    - podSelector:
        matchLabels:
          app: elasticsearch
  # Allow pods to talk to DNS to resolve service names
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

---

## File: `./install/05-services.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: es-svc # Headless service for StatefulSet discovery
  namespace: elastic
  labels:
    app: elasticsearch
spec:
  publishNotReadyAddresses: true 
  ports:
  - port: 9200
    name: http
    targetPort: 9200
  - port: 9300
    name: transport
    targetPort: 9300
  clusterIP: None # This makes it a headless service
  selector:
    app: elasticsearch
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-client # Service for client access
  namespace: elastic
  labels:
    app: elasticsearch
spec:
  type: ClusterIP # Exposes the service on an internal IP in the cluster
  ports:
  - port: 9200
    # name: http
    targetPort: 9200
  selector:
    app: elasticsearch
```

---

## File: `./certs/02-secrets.yaml.template`

```template
apiVersion: v1
kind: Secret
metadata:
  name: elastic-certificates
  namespace: elastic
type: Opaque
data:
  ca.crt: |
    ${CA_CRT_B64}
  ca.key: |
    ${CA_KEY_B64}
  node.crt: |
    ${NODE_CRT_B64}
  node.key: |
    ${NODE_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: elastic-credentials
  namespace: elastic
type: Opaque
stringData:
  elastic-password: <YOUR_ELASTIC_PASSWORD> # IMPORTANT: Replace with the actual password you set!
```

---

## File: `./certs/01-security-setup-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: es-cert-generator
  namespace: elastic
spec:
  containers:
  - name: es-cert-generator
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.5
    command: ["sleep", "3600"] # Keep the pod running for manual operations
    volumeMounts:
    - name: certs-volume
      mountPath: /usr/share/elasticsearch/certs
  volumes:
  - name: certs-volume
    emptyDir: {} # Temporary volume for certs
  restartPolicy: Never
```

---

## File: `./certs/generate_keystore_secret.sh`

```sh
#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# --- Configuration ---
# Set the Kubernetes namespace where the resources will be created and found.
NAMESPACE="elastic"
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

# Create PKCS12 file
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  openssl pkcs12 -export \
  -in /mnt/certs/node.crt \
  -inkey /mnt/certs/node.key \
  -out /tmp/${P12_FILE} \
  -name elastic-node \
  -certfile /mnt/certs/ca.crt \
  -passout "pass:${KEYSTORE_PASSWORD}"

# Convert PKCS12 to JKS
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  keytool -importkeystore \
  -deststorepass "${KEYSTORE_PASSWORD}" \
  -destkeystore /tmp/${JKS_FILE} \
  -srckeystore /tmp/${P12_FILE} \
  -srcstoretype PKCS12 \
  -srcstorepass "${KEYSTORE_PASSWORD}" \
  -noprompt

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
```

---

## File: `./certs/generate_secrets_yaml.sh`

```sh
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
```

---

## File: `./elastic.md`

```md
# Concatenated File Contents

## File: `./install/post_deployment.sh`

```sh
#!/bin/bash

# --- Configuration ---
NAMESPACE="elastic"
CONFIGMAP_NAME="elasticsearch-config"
STATEFULSET_NAME="elasticsearch" # IMPORTANT: Change this to your StatefulSet's name
KEY_TO_MODIFY="elasticsearch.yml"
LINE_TO_REMOVE="cluster.initial_master_nodes"
# --- End of Configuration ---

# Step 1: Get the entire original ConfigMap YAML.
echo "Fetching current ConfigMap '$CONFIGMAP_NAME'..."
original_cm_yaml=$(kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get ConfigMap. Aborting."
    exit 1
fi

# Step 2: Extract the raw string content of the 'elasticsearch.yml' key.
# We use yq for this to handle YAML structure correctly.
es_yml_content=$(echo "$original_cm_yaml" | yq e '.data["'${KEY_TO_MODIFY}'"]')

# Step 3: Modify the extracted string content using sed.
modified_es_yml_content=$(echo "$es_yml_content" | sed "/${LINE_TO_REMOVE}/d")

# Step 4: Use yq to create the final YAML, replacing the old content with the modified content.
# We export the variable so yq's 'strenv' can read it, preserving all special characters and newlines.
export MODIFIED_CONTENT_VAR="$modified_es_yml_content"
final_cm_yaml=$(echo "$original_cm_yaml" | yq e '.data["'${KEY_TO_MODIFY}'"] = strenv(MODIFIED_CONTENT_VAR)')

# Step 5: Apply the final, corrected YAML to the cluster.
echo "Applying patched ConfigMap..."
echo "$final_cm_yaml" | kubectl apply -f -
if [ $? -ne 0 ]; then
    echo "Error: Failed to apply the patched ConfigMap. Aborting."
    exit 1
fi

echo "ConfigMap patched successfully."
echo "---"

# Step 6: Trigger the rolling restart of the StatefulSet.
echo "Initiating a rolling restart for StatefulSet '$STATEFULSET_NAME'..."
kubectl rollout restart statefulset/"$STATEFULSET_NAME" -n "$NAMESPACE"

echo "StatefulSet restart initiated. Monitor the pod rollout status with:"
echo "kubectl rollout status statefulset/$STATEFULSET_NAME -n $NAMESPACE --watch"
```

---

## File: `./install/tear_down.sh`

```sh
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

echo "8. Checking for and deleting Kibana resources (if deployed)..."
kubectl delete deployment kibana -n "$NAMESPACE" --ignore-not-found=true
kubectl delete svc kibana-svc -n "$NAMESPACE" --ignore-not-found=true
if [ $? -eq 0 ]; then
    echo "   Kibana resources deleted successfully (or not found)."
else
    echo "   Error deleting Kibana resources. Continuing anyway."
fi

echo "------------------------------------------------------------------"
echo "Elasticsearch cluster teardown complete in namespace: $NAMESPACE."
echo "The namespace '$NAMESPACE' itself has NOT been deleted."
echo "You may want to manually check for any remaining Persistent Volumes (PVs) if your StorageClass does not automatically reclaim them:"
echo "  kubectl get pv | grep elastic"
echo "If any PVs are stuck in 'Released' or 'Failed' state, you might need to delete them manually:"
echo "  kubectl delete pv <pv-name>"
```

---

## File: `./install/04-statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: elastic
spec:
  podManagementPolicy: "Parallel"
  serviceName: es-svc
  replicas: 3 # Recommended 3 master-eligible nodes for production
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      # Optional: Node Selector or Tolerations for specific nodes
      # nodeSelector:
      #   node-role.kubernetes.io/data: "true"

      # Pod Anti-Affinity for High Availability
      securityContext:
        fsGroup: 1000        # Ensure the volume's group ID is 1000
        # runAsUser: 1000      # Run containers as user ID 1000 (Elasticsearch user)
        # runAsGroup: 1000     # Run containers as group ID 1000     
        # fsGroupChangePolicy: "Always"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: elasticsearch
              topologyKey: kubernetes.io/hostname # Spread pods across different nodes
      
      initContainers:
      - name: sysctl
        image: busybox:1.36.1 # Use a recent busybox image
        command: ["sh", "-c", "sysctl -w vm.max_map_count=262144"]
        securityContext:
          privileged: true # Required for sysctl
          runAsUser: 0           # Run init container as root to ensure sysctl works
          runAsGroup: 0
      # - name: setup-keystore
      #   image: docker.elastic.co/elasticsearch/elasticsearch:8.15.5
      #   command:
      #     - /bin/bash
      #     - -c
      #     - |
      #       set -e
      #       echo "Setting up Elasticsearch Keystore..."
      #       # Create an empty keystore if it doesn't exist
      #       if [ ! -f config/elasticsearch.keystore ]; then
      #         echo "Creating new keystore..."
      #         bin/elasticsearch-keystore create
      #       fi
      #       # Add the bootstrap password from the secret. The '|| true' prevents failure if the key already exists on restart.
      #       echo "$ELASTIC_PASSWORD" | bin/elasticsearch-keystore add -x 'bootstrap.password' || true
      #       echo "Keystore setup complete."
        # env:
        #   - name: ELASTIC_PASSWORD
        #     valueFrom:
        #       secretKeyRef:
        #         name: elastic-credentials
        #         key: elastic-password
        # volumeMounts:
        # # Note: We only need to mount the 'data' volume here, as the keystore
        # # is written to the persistent data directory. The main container will
        # # then have access to it.
        # - name: data
        #   mountPath: /usr/share/elasticsearch/data
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:8.18.4
        env:
          - name: ELASTIC_PASSWORD
            valueFrom:
              secretKeyRef:
                name: elastic-credentials
                key: elastic-password          
          - name: NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: CLUSTER_NAME
            value: elasticsearch-cluster
          # - name: DISCOVERY_SERVICE
          #   value: es-svc.elastic.svc.cluster.local
          - name: ES_JAVA_OPTS
            # Adjust based on your node memory. Typically 50% of allocated memory, but not more than 30.5GB.
            # Example: for 4GiB memory limit, set Xms/Xmx to 2g
            value: "-Xms2g -Xmx2g" # Example: 2GB heap. Adjust for your actual needs.
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          # Optional: Add any other environment variables for Elasticsearch configuration
          # - name: xpack.monitoring.collection.enabled
          #   value: "true"
          # - name: CLUSTER_INITIAL_MASTER_NODES # <<< ADD THIS ENVIRONMENT VARIABLE
          #   value: "elasticsearch-0,elasticsearch-1,elasticsearch-2" 
        resources:
          requests:
            memory: 4Gi # Request 4GB memory
            cpu: 1 # Request 1 CPU core
          limits:
            memory: 4Gi # Limit to 4GB memory
            cpu: 2 # Limit to 2 CPU cores (burst capacity)
        
        ports:
        - containerPort: 9200 # HTTP
          name: http
        - containerPort: 9300 # Transport
          name: transport
        
        volumeMounts:
        - name: config
          mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
          subPath: elasticsearch.yml
        - name: config
          mountPath: /usr/share/elasticsearch/config/log4j2.properties
          subPath: log4j2.properties
        - name: certs
          mountPath: /usr/share/elasticsearch/config/certs
        - name: data
          mountPath: /usr/share/elasticsearch/data
        
        # securityContext:
        #   allowPrivilegeEscalation: false # Prevent processes from gaining more privileges
        #   readOnlyRootFilesystem: true    # Make root filesystem read-only (all writes to mounted volumes)
        #   runAsNonRoot: true              # Ensure container runs as non-root user (UID 1000)
        # Health Checks
        startupProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS # Use HTTPS for secure cluster
          #   path: /_cluster/health?wait_for_status=green&timeout=1s
            port: 9200
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 60 # Allow 5 minutes for startup
        livenessProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS
          #   path: /_cluster/health?timeout=1s
            port: 9200
          initialDelaySeconds: 30 # Give some time after startup
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          tcpSocket:
          # httpGet:
          #   scheme: HTTPS
          #   path: /_cluster/health?timeout=1s
            port: 9200
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 5
          failureThreshold: 3

      volumes:
      - name: config
        configMap:
          name: elasticsearch-config
      - name: certs
        secret:
          secretName: elastic-certificates
  
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ] # Must be ReadWriteOnce for StatefulSets
      resources:
        requests:
          storage: 50Gi # Adjust storage size as needed for production data
      # storageClassName: your-custom-storage-class # Uncomment and set if not using default
```

---

## File: `./install/07-pod-disruption-budget.yaml`

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: elasticsearch-pdb
  namespace: elastic
spec:
  minAvailable: 2 # Allow at most 1 node to be unavailable at a time (for a 3 node cluster)
  selector:
    matchLabels:
      app: elasticsearch
```

---

## File: `./install/03-configmaps.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
  namespace: elastic
data:
  elasticsearch.yml: |
    cluster.name: elasticsearch-cluster
    node.name: ${POD_NAME}

    node.roles: [ master, data, ingest ]    
    
    network.host: 0.0.0.0
    http.port: 9200
    transport.port: 9300

    # Paths
    path.data: /usr/share/elasticsearch/data
    path.logs: /usr/share/elasticsearch/logs

    # Security (TLS)
    xpack.security.enabled: true
    xpack.security.http.ssl.enabled: true
    xpack.security.http.ssl.certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
    xpack.security.http.ssl.certificate: /usr/share/elasticsearch/config/certs/node.crt
    xpack.security.http.ssl.key: /usr/share/elasticsearch/config/certs/node.key
    xpack.security.transport.ssl.enabled: true
    xpack.security.transport.ssl.verification_mode: certificate
    # xpack.security.transport.ssl.verification_mode: none
    xpack.security.transport.ssl.certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
    xpack.security.transport.ssl.certificate: /usr/share/elasticsearch/config/certs/node.crt
    xpack.security.transport.ssl.key: /usr/share/elasticsearch/config/certs/node.key

    # Discovery
    discovery.seed_hosts: ["es-svc.elastic.svc.cluster.local"]
    cluster.initial_master_nodes: ["elasticsearch-0", "elasticsearch-1", "elasticsearch-2"] # Assuming 3 initial nodes

    # Heap size (adjust based on your node memory)
    # ES_JAVA_OPTS will override this, but good to have a default here too for clarity
    # ES will auto-detect up to 50% of available memory, or 32GB
    # For production, set ES_JAVA_OPTS correctly based on K8s limits
    # xpack.ml.enabled: false # Disable ML if not needed to save resources
    # xpack.security.enrollment.enabled: true # Enable for simplified setup with Kibana
    # xpack.security.http.ssl.client_authentication: optional # Optional for client auth
  log4j2.properties: |
    status = error
    name = elasticsearch-config
    appender.console.type = Console
    appender.console.name = console
    appender.console.layout.type = PatternLayout
    appender.console.layout.pattern = [%d{ISO8601}][%-5p][%-25c{1.}] %marker%m%n
    rootLogger.level = info 
    rootLogger.appenderRef.console.ref = console
```

---

## File: `./install/06-network-policy.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: elasticsearch-network-policy  # Same name, so it will replace the old one
  namespace: elastic
spec:
  # Apply this policy to all pods with the 'app=elasticsearch' label
  podSelector:
    matchLabels:
      app: elasticsearch
  policyTypes:
  - Ingress
  - Egress

  # Define rules for INCOMING traffic
  ingress:
  - from:
      # Allow traffic FROM other Elasticsearch pods
      - podSelector:
          matchLabels:
            app: elasticsearch
      # Allow traffic FROM any pod in the same 'elastic' namespace
      # This is useful for clients or other tools in the same namespace
      - namespaceSelector:
          matchLabels:
            # Use a standard label that is present on all namespaces by default
            kubernetes.io/metadata.name: elastic
  - from:
    - namespaceSelector:
        matchLabels:
          # This assumes your pegabackingservices namespace is labeled this way.
          # Check with 'kubectl get ns --show-labels'
          kubernetes.io/metadata.name: pegabackingservices
    ports:
    # On the following ports
    - protocol: TCP
      port: 9200  # for HTTP, clients, and probes
    - protocol: TCP
      port: 9300  # for inter-node transport/clustering

  # Define rules for OUTGOING traffic
  egress:
  # Allow pods to talk to each other
  - to:
    - podSelector:
        matchLabels:
          app: elasticsearch
  # Allow pods to talk to DNS to resolve service names
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

---

## File: `./install/05-services.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: es-svc # Headless service for StatefulSet discovery
  namespace: elastic
  labels:
    app: elasticsearch
spec:
  publishNotReadyAddresses: true 
  ports:
  - port: 9200
    name: http
    targetPort: 9200
  - port: 9300
    name: transport
    targetPort: 9300
  clusterIP: None # This makes it a headless service
  selector:
    app: elasticsearch
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-client # Service for client access
  namespace: elastic
  labels:
    app: elasticsearch
spec:
  type: ClusterIP # Exposes the service on an internal IP in the cluster
  ports:
  - port: 9200
    # name: http
    targetPort: 9200
  selector:
    app: elasticsearch
```

---

## File: `./certs/02-secrets.yaml.template`

```template
apiVersion: v1
kind: Secret
metadata:
  name: elastic-certificates
  namespace: elastic
type: Opaque
data:
  ca.crt: |
    ${CA_CRT_B64}
  ca.key: |
    ${CA_KEY_B64}
  node.crt: |
    ${NODE_CRT_B64}
  node.key: |
    ${NODE_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: elastic-credentials
  namespace: elastic
type: Opaque
stringData:
  elastic-password: <YOUR_ELASTIC_PASSWORD> # IMPORTANT: Replace with the actual password you set!
```

---

## File: `./certs/01-security-setup-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: es-cert-generator
  namespace: elastic
spec:
  containers:
  - name: es-cert-generator
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.5
    command: ["sleep", "3600"] # Keep the pod running for manual operations
    volumeMounts:
    - name: certs-volume
      mountPath: /usr/share/elasticsearch/certs
  volumes:
  - name: certs-volume
    emptyDir: {} # Temporary volume for certs
  restartPolicy: Never
```

---

## File: `./certs/generate_keystore_secret.sh`

```sh
#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# --- Configuration ---
# Set the Kubernetes namespace where the resources will be created and found.
NAMESPACE="elastic"
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

# Create PKCS12 file
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  openssl pkcs12 -export \
  -in /mnt/certs/node.crt \
  -inkey /mnt/certs/node.key \
  -out /tmp/${P12_FILE} \
  -name elastic-node \
  -certfile /mnt/certs/ca.crt \
  -passout "pass:${KEYSTORE_PASSWORD}"

# Convert PKCS12 to JKS
kubectl exec -n ${NAMESPACE} ${TEMP_POD_NAME} -- \
  keytool -importkeystore \
  -deststorepass "${KEYSTORE_PASSWORD}" \
  -destkeystore /tmp/${JKS_FILE} \
  -srckeystore /tmp/${P12_FILE} \
  -srcstoretype PKCS12 \
  -srcstorepass "${KEYSTORE_PASSWORD}" \
  -noprompt

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
```

---

## File: `./certs/generate_secrets_yaml.sh`

```sh
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
```
