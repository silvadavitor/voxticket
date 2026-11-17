# Runner de Terraform + Terragrunt usado pelo container infra-init do compose.
FROM hashicorp/terraform:1.17.2

ARG TERRAGRUNT_VERSION=1.2.2
ARG TARGETARCH=amd64

RUN wget -qO /usr/local/bin/terragrunt \
      "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_${TARGETARCH}" \
 && chmod +x /usr/local/bin/terragrunt \
 && terragrunt --version

ENTRYPOINT ["/bin/sh", "-c"]
