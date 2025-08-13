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
kubectl -f apply install/ -n elastic
kubectl rollout status statefulset/elasticsearch -n elastic --watch

# Once the elastcsearch cluster is bootstrapped
./install/post_deployment.sh
kubectl rollout status statefulset/elasticsearch -n elastic --watch
```

## Rotate elasticsearch certs

Will detect existing ca.crt in cluster, regenerate node certs and update the secret inside the cluster.

Perform 


```bash
# assuming you are in the root of your cloned directory
cd elastic/certs
./generate_certs_secret.sh
kubectl rollout restart statefulset/elasticsearch -n elastic
kubectl rollout status statefulset/elasticsearch -n elastic --watch
```

## Tear down the cluster fully.

Beware this will completely remove elastic search from your cluster.  Namespace will remain.

```bash
# assuming you are in the root of your cloned directory
cd elastic/install
./teardown.sh
```

