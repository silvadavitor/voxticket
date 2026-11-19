# ADR-005 — Front estático em S3 + CloudFront

**Status:** aceito · 18/11/2026

## Contexto
O foco do trabalho são os microsserviços e a API. Para apresentar à turma, precisamos de uma tela
simples: enviar um áudio e acompanhar a saga.

## Decisão
- O front é **HTML, CSS e JavaScript puro**, sem build e sem servidor de aplicação. Ele só chama a
  API (`POST /audios`, `GET /audios/{id}`).
- **AWS:** os arquivos ficam num **S3 privado**, lido apenas pelo **CloudFront** via Origin Access
  Control. O CloudFront entrega o site com **HTTPS** (`*.cloudfront.net`) e repassa `/api/*` para o ALB;
  uma CloudFront Function tira o prefixo `/api`. Site e API ficam na mesma origem, sem CORS.
- **Local:** o Terraform publica os arquivos no S3 do MiniStack, e um nginx faz o papel do CloudFront
  (site do bucket + `/api` → request-service).
- A configuração (URL da API, links do Grafana e do RabbitMQ) vai num `config.js` gerado pelo Terraform.
- Sem a API no ar, a página entra em **modo demo** e simula a saga seguindo o mesmo contrato.

## Por quê
- Site estático em S3 + CDN é o padrão da AWS: barato, sem servidor para manter, cacheado na borda.
- O CloudFront dá HTTPS de graça, o que resolve o ALB sem certificado (não temos domínio próprio).
- Tudo continua sendo infra como código, igual ao resto.

## Alternativas
- **Container com o front no ECS:** mais um serviço para operar e pagar, sem ganho.
- **S3 static website hosting público:** sem HTTPS e com bucket público.
