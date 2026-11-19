#!/usr/bin/env bash
# Copia de contracts/schemas (fonte da verdade) os schemas que este serviço usa; o build parte desta pasta.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in envelope TicketOpened.v1 RequestFailed.v1; do cp "../../contracts/schemas/$f.schema.json" "contracts/$f.schema.json"; done
echo "contratos sincronizados"
