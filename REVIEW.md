# Review

This repo provides Kubernetes manifests and helper scripts to deploy an Elasticsearch 8.x cluster and an Apache Kafka 3.9.x KRaft (separate controller/broker) cluster, including TLS/secret generation flows. The overall direction is solid: it is close to a usable “quikstart” for secure clusters. Below are strengths, risks, and concrete improvements.

## What’s working well

### Elasticsearch
- **Clear install/rotate/teardown flows.** `elastic/README.md` and the cert scripts map to distinct operator tasks and are easy to follow.
- **TLS by default.** Manifests enable `xpack.security.*` and mount cert secrets; probes and services are aligned with the secured setup.
- **HA‑aware scheduling.** Pod anti‑affinity and a 3‑replica StatefulSet are sensible defaults.
- **Bootstrap cleanup script.** `elastic/install/post_deployment.sh` removing `cluster.initial_master_nodes` after bootstrapping is correct for ES clusters.

### Kafka
- **Correct KRaft split.** Separate controller and broker StatefulSets with `process.roles` and quorum voters are properly modeled.
- **Config templating per‑pod.** The init container pattern that materializes `server.properties` into an `emptyDir` is a clean way to inject ordinal‑specific IDs and advertised listeners.
- **Storage formatting guarded.** Brokers check for `meta.properties` before running `kafka-storage.sh format`, preventing restart failures; controllers use `--ignore-formatted`.
- **TLS setup covers broker/controller/client.** Cert generation script produces keystore/truststores for all three roles.

## Key issues / risks

### Cross‑cutting
- **Hard‑coded passwords and cluster IDs.**
  - Kafka uses a fixed `PASSWORD="install123!"` in `kafka/certs/generate_kafka_secrets.sh` and hard‑coded `ssl.*.password` values in ConfigMaps. This is a security risk and makes rotation painful.
  - Kafka cluster ID is fixed in both StatefulSets (`KAFKA_CLUSTER_ID="io9BKK6KRpSRz2uIOTva-g"`). If users redeploy from scratch and forget to wipe PVCs, mismatches can cause confusing errors.
- **Scripts assume local tools without checks.**
  - `elastic/install/post_deployment.sh` depends on `yq` and `kubectl` but doesn’t validate presence/version.
  - Cert scripts assume `envsubst`, `base64 -w 0`, and GNU coreutils behavior.
- **Namespace/label assumptions.** Some files assume namespaces exist or have specific labels (e.g., ES NetworkPolicy references `pegabackingservices` by label). If labels differ, traffic may silently fail.

### Elasticsearch specifics
- **`tear_down.sh` vs README mismatch.** `elastic/README.md` calls `elastic/install/teardown.sh`, but the script shown in `elastic/elastic.md` is named `tear_down.sh`. This will break copy‑paste installs unless both exist.
- **Privileged sysctl init container.** The ES StatefulSet uses a privileged BusyBox init container to set `vm.max_map_count`. This is common, but some clusters block privileged pods; fallback guidance is missing.
- **Resource defaults may be too rigid.** Heap is pinned to `-Xms2g -Xmx2g` with 4Gi limits. On smaller nodes this may not schedule; on bigger nodes it under‑utilizes capacity.
- **NetworkPolicy is permissive on egress.** It allows egress to all pods with `app=elasticsearch` but otherwise doesn’t restrict other outbound traffic besides DNS. If the goal is isolation, it should be tightened or documented as “baseline”.

### Kafka specifics
- **`fsGroup: 0` for volume writes.** Both StatefulSets set `fsGroup: 0`. This works but is effectively “root group” and may violate Pod Security Standards. Prefer a non‑root UID/GID aligned with the Kafka image.
- **Advertised listeners use internal DNS only.** `advertised.listeners` is set to pod DNS names. This is fine for in‑cluster access, but there’s no documented external access pattern besides a bootstrap Service in `external_broker/`.
- **Secret creation output not applied.** `generate_kafka_secrets.sh` writes YAML files but doesn’t apply them (commented out delete/cleanup too). Users can easily forget the next step.

## Recommended improvements (actionable)

## Notes from hardening (practical)

- **Kafka + `readOnlyRootFilesystem`.** The Apache Kafka image can fail fast if JVM GC logging is configured to write under `/opt/kafka/.../logs` on a read-only root filesystem. If enabling ROFS, ensure GC logs are redirected to a writable mount (for example `/tmp`) via Kafka/JVM env overrides, and validate by restarting non-zero ordinals first (StatefulSet ordering can mask whether a fix is applied).
- **Client config templating.** Unlike brokers/controllers (which can template `server.properties` in an init container), a plain client ConfigMap with placeholders won’t work unless the client deployment also performs templating at runtime (init container or entrypoint wrapper) or the passwords are injected from Secrets directly.
- **Client secrets in other namespaces.** Client TLS/password secrets cannot be referenced cross-namespace. To support “clients in any namespace”, ship Secret manifests without `metadata.namespace` and apply them with `kubectl apply -n <client-ns> ...`, or template them as part of the client deployment in that namespace.

### Security and configurability
1. **Parameterize secrets and IDs.**
   - Read Kafka keystore/truststore password from an env var (with prompt fallback) and avoid writing it into ConfigMaps in cleartext; instead mount a secret and reference via `ssl.*.password` envs or `server.properties` created by init.
   - Allow `KAFKA_CLUSTER_ID` to be provided externally (env or args). Consider a script to generate/print a new UUID.
2. **Avoid `fsGroup: 0`.** Switch to the Kafka image’s expected UID/GID (often 1000) and set `runAsUser`, `runAsGroup`, and `fsGroup` accordingly.
3. **Document cert rotation.**
   - ES cert script supports rotation via CA bundling; explain the two‑phase rotation in docs.
   - Kafka cert script currently regenerates everything; note that this requires coordinated rolling restarts.

### Operational robustness
4. **Fix teardown naming and paths.** Ensure README matches real filenames and `kubectl apply` examples use correct syntax (`kubectl apply -f install/ -n elastic`).
5. **Add preflight checks to scripts.**
   - Verify `kubectl` context/namespace access.
   - Verify required binaries (`yq`, `envsubst`, `keytool`, `base64`).
   - Fail fast with clear messages.
6. **Make resource settings tunable.**
   - Move ES JVM opts and requests/limits into a ConfigMap or Helm‑style values file.
   - For Kafka, consider requests/limits and heap opts per role.

### Documentation polish
7. **Add a Kafka README.** Mirror ES docs: install steps, cert generation, bootstrap service, client test usage, teardown.
8. **Explain external access.** If the intent is internal‑only, say so; otherwise include NodePort/LoadBalancer/Ingress patterns and the required `advertised.listeners` changes.
9. **State cluster prerequisites.** PodSecurity/PSA expectations, storage class requirements, and minimum node sizes.

## Overall assessment
The repo is a strong base for secure ES/Kafka quickstarts. The biggest gaps are around security hygiene (hard‑coded passwords/IDs), a couple of documentation/filename mismatches, and portability to stricter Kubernetes environments. Addressing those will make this genuinely production‑ready for most teams.
