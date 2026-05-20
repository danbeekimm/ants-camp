FROM --platform=linux/amd64 prom/prometheus:v2.53.0

COPY --chown=nobody:nobody prometheus.yaml /etc/prometheus/prometheus.yaml
COPY --chown=nobody:nobody alert-rules.yaml /etc/prometheus/alert-rules.yaml

CMD ["--config.file=/etc/prometheus/prometheus.yaml", \
     "--storage.tsdb.retention.time=14d"]
