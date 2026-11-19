#!/usr/bin/env bash
# Copia de contracts/ (fonte da verdade) os schemas que este serviço usa. O build da imagem parte desta
# pasta, então eles precisam estar aqui. O teste test_contracts_in_sync falha se divergirem.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in envelope TranscriptionRequested.v1 TranscriptDiscardRequested.v1 AudioTranscribed.v1 TranscriptionFailed.v1; do
  cp "../../contracts/schemas/$f.schema.json" "contracts/$f.schema.json"
done
echo "contratos sincronizados"
