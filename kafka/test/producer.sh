kubectl exec -ti kafka-client-test -n kafka -- /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server kafka-broker-0.kafka-headless.kafka.svc.cluster.local:9094,kafka-broker-1.kafka-headless.kafka.svc.cluster.local:9094,kafka-broker-2.kafka-headless.kafka.svc.cluster.local:9094 \
    --producer.config /etc/kafka-client/config/client.properties \
    --topic it-works-for-real-this-time
