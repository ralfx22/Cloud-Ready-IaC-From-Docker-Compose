# build tools in a normal Linux image
FROM alpine:3.20 AS tools

ARG TF_VERSION=1.14.3
ARG KOMPOSE_VERSION=v1.34.0

RUN apk add --no-cache curl unzip ca-certificates

# kubectl (latest stable)
RUN curl -L "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# kompose (pinned)
RUN curl -L "https://github.com/kubernetes/kompose/releases/download/${KOMPOSE_VERSION}/kompose-linux-amd64" \
    -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose

# terraform (pinned)
RUN curl -L "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
 && unzip /tmp/terraform.zip -d /usr/local/bin \
 && rm -f /tmp/terraform.zip \
 && chmod +x /usr/local/bin/terraform

# final image = n8n + copied binaries
FROM docker.n8n.io/n8nio/n8n:2.18.5

USER root

# Ensure CA bundle exists (needed for HTTPS in kubectl/terraform)
RUN mkdir -p /etc/ssl/certs

COPY --from=tools /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=tools /usr/local/bin/kompose /usr/local/bin/kompose
COPY --from=tools /usr/local/bin/terraform /usr/local/bin/terraform
COPY --from=tools /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

USER node
