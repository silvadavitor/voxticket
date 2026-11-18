#!/usr/bin/env bash
# Copia os JSON Schemas que este serviço usa de contracts/ (fonte da verdade) para app/contracts/.
# O build do Docker só enxerga esta pasta, por isso a cópia. O teste test_contracts_em_dia falha se divergir.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in envelope.schema.json CategorizationRequested.v1.schema.json AudioCategorized.v1.schema.json; do
  cp "../../contracts/schemas/$f" "app/contracts/$f"
done
echo "contratos sincronizados"
