#!/bin/bash
set -euo pipefail

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command '$1' not found in PATH." >&2
        exit 1
    }
}

require_cmd kubectl
require_cmd yq
require_cmd sed

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
