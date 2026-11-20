# Aplica rabbitmq/definitions.json via API de management (container local e RabbitMQ da EC2 na AWS).
FROM alpine:3.22
RUN apk add --no-cache curl
COPY rabbitmq/definitions.json /definitions.json
COPY infra/scripts/rabbitmq-init.sh /usr/local/bin/rabbitmq-init.sh
RUN chmod +x /usr/local/bin/rabbitmq-init.sh
ENTRYPOINT ["/usr/local/bin/rabbitmq-init.sh"]
