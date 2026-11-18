#!/usr/bin/env bash
# Copia os JSON Schemas que este serviço usa de contracts/ (fonte da verdade) para dentro do pacote
# envelope, que os embute no binário (go:embed). O teste TestContratosEmDia falha se divergir.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in envelope.schema.json CategorizationRequested.v1.schema.json AudioCategorized.v1.schema.json; do
  cp "../../contracts/schemas/$f" "internal/envelope/contracts/$f"
done
echo "contratos sincronizados"
