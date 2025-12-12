# Kafka (KRaft) on Kubernetes

This directory contains manifests and scripts to deploy a TLS‑secured Apache Kafka 3.9.x cluster using KRaft mode with separate controller and broker StatefulSets.

## Install

```bash
kubectl create ns kafka

# Generate TLS keystores/truststores and secret YAMLs
cd kafka/certs
./generate_kafka_secrets.sh

# Apply the generated secrets
kubectl apply -f kafka-certs/kafka-controller-secrets.yaml -n kafka
kubectl apply -f kafka-certs/kafka-broker-secrets.yaml -n kafka
kubectl apply -f kafka-certs/kafka-client-secrets.yaml -n kafka

# Deploy controllers, brokers, and client test pod
cd ..
kubectl apply -f install/ -n kafka
kubectl apply -f install_client/ -n kafka
```

Wait for rollouts:

```bash
kubectl rollout status statefulset/kafka-controller -n kafka --watch
kubectl rollout status statefulset/kafka-broker -n kafka --watch
```

## Configuration notes

- **Cluster ID**: `install/kafka-cluster-configmap.yaml` holds `cluster.id`. Change this value when creating a brand new cluster (and after deleting PVCs) to avoid KRaft format mismatches.
- **TLS passwords**: Kafka configs contain `SSL_PASSWORD_PLACEHOLDER`. The init containers replace this using `KAFKA_SSL_PASSWORD` in each StatefulSet. Update that env value (or wire it to a Secret) to rotate passwords.
- **External access**: Manifests default to in‑cluster DNS (`advertised.listeners` uses pod DNS). For external access, add a `LoadBalancer`/`NodePort` service and adjust `advertised.listeners` accordingly.

## Quick test

```bash
# Create a topic from the client pod
kubectl exec -n kafka kafka-client -- \
  /opt/kafka/bin/kafka-topics.sh --create --topic test --bootstrap-server kafka-broker-0.kafka-headless.kafka.svc.cluster.local:9094 \
  --command-config /etc/kafka-client/client.properties

# Produce/consume
kubectl exec -n kafka kafka-client -- /test/producer.sh test
kubectl exec -n kafka kafka-client -- /test/consumer.sh test
```

## Teardown

```bash
cd kafka/install
./kafka-teardown.sh
```

This deletes StatefulSets, Services, ConfigMaps, and PVCs, leaving Secrets intact for a fresh redeploy.

