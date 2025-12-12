# Elasticsearch

## Fresh install on k8s cluster.

```bash
kubectl create ns elastic
kubectl create ns pegabackingservices

# assuming you are in the root of your cloned directory
cd elastic/certs
./generate_elasticsearch_secrets.sh
./generate_elasticsearch_keystore_secret.sh
```
Secrets have now been generated and added to k8s.

Next thing is to install elasticsearch.

```bash
# assuming you are in the root of your cloned directory
cd elastic 
kubectl apply -f install/ -n elastic
kubectl rollout status statefulset/elasticsearch -n elastic --watch

# Once the elasticsearch cluster is bootstrapped
./install/post_deployment.sh
kubectl rollout status statefulset/elasticsearch -n elastic --watch
```

## Rotate elasticsearch certs

Will detect existing ca.crt in cluster, regenerate node certs and update the secret inside the cluster.

Perform 


```bash
# assuming you are in the root of your cloned directory
cd elastic/certs
./generate_elasticsearch_secrets.sh
kubectl rollout restart statefulset/elasticsearch -n elastic
kubectl rollout status statefulset/elasticsearch -n elastic --watch
```

Rotation is two‑phase: the first run bundles old+new CAs so nodes trust both. After the rollout completes, run `./generate_elasticsearch_secrets.sh` again to remove the old CA from the bundle.

## Network policy

`install/06-network-policy.yaml` allows access from the `pegabackingservices` namespace by label. Ensure that namespace has the label `kubernetes.io/metadata.name=pegabackingservices`, or adjust the policy.

## Tear down the cluster fully.

Beware this will completely remove elastic search from your cluster.  Namespace will remain.

```bash
# assuming you are in the root of your cloned directory
cd elastic/install
./tear_down.sh
```
