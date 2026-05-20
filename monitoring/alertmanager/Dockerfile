FROM --platform=linux/amd64 prom/alertmanager:v0.28.1

USER root
COPY alertmanager.yaml /etc/alertmanager/alertmanager.yaml.tmpl
RUN chmod 644 /etc/alertmanager/alertmanager.yaml.tmpl

# 런타임에 sed로 환경변수 치환 후 실행
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["sed -e \"s|\\${SLACK_ALERTMANAGER_WEBHOOK_URL}|${SLACK_ALERTMANAGER_WEBHOOK_URL}|g\" -e \"s|\\${WEBHOOK_SHARED_SECRET}|${WEBHOOK_SHARED_SECRET}|g\" /etc/alertmanager/alertmanager.yaml.tmpl > /tmp/am.yaml && /bin/alertmanager --config.file=/tmp/am.yaml"]
