#!/usr/bin/env bash
# Copia de contracts/schemas (fonte da verdade) os schemas que este serviço usa; o build parte desta pasta.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in envelope AudioReceived.v1 CreditReserved.v1 CreditRejected.v1 TranscriptionRequested.v1 AudioTranscribed.v1 TranscriptionFailed.v1 TranscriptDiscardRequested.v1 CategorizationRequested.v1 AudioCategorized.v1 TicketRequested.v1 TicketOpened.v1 TicketRejected.v1 CreditReleaseRequested.v1 RequestFailed.v1; do cp "../../contracts/schemas/$f.schema.json" "contracts/$f.schema.json"; done
echo "contratos sincronizados"
