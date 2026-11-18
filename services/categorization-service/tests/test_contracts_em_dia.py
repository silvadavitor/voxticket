"""Os schemas copiados em app/contracts/ precisam ser iguais aos de contracts/ (fonte da verdade)."""

from pathlib import Path

import pytest

SERVICE = Path(__file__).resolve().parent.parent
SOURCE = SERVICE.parent.parent / "contracts" / "schemas"


@pytest.mark.skipif(not SOURCE.exists(), reason="fora do repositório (ex.: dentro do container)")
@pytest.mark.parametrize("arquivo", sorted(p.name for p in (SERVICE / "app" / "contracts").glob("*.json")))
def test_contrato_sincronizado(arquivo):
    assert (SERVICE / "app" / "contracts" / arquivo).read_text() == (SOURCE / arquivo).read_text(), (
        f"{arquivo} desatualizado: rode scripts/sync-contracts.sh"
    )
