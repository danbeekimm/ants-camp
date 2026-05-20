FROM --platform=linux/amd64 grafana/loki:2.9.8

COPY loki.yaml /etc/loki/loki.yaml

CMD ["-config.file=/etc/loki/loki.yaml"]
