# Stack de observabilidade (Grafana + Tempo + Prometheus + Loki) com o dashboard do VoxTicket embutido.
# Mesma imagem local (docker compose) e na AWS (ECS). Grafana na porta 3000, OTLP em 4317/4318.
FROM grafana/otel-lgtm:0.40.0

COPY observability/grafana/dashboards.yaml /otel-lgtm/grafana/conf/provisioning/dashboards/voxticket.yaml
COPY observability/grafana/voxticket.json observability/grafana/servicos.json observability/grafana/logs.json observability/grafana/traces.json \
     /otel-lgtm/grafana/conf/provisioning/dashboards/voxticket/
# fontes de dados da imagem, com a janela do "Related logs" ampliada
COPY observability/grafana/datasources.yaml /otel-lgtm/grafana/conf/provisioning/datasources/grafana-datasources.yaml
