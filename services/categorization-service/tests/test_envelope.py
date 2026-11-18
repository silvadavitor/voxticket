import json
import uuid

import pytest

from app.messaging.envelope import Envelope, InvalidMessage, new_envelope


def _msg(**over):
    req = str(uuid.uuid4())
    env = {
        "messageId": str(uuid.uuid4()),
        "correlationId": req,
        "type": "CategorizationRequested",
        "version": 1,
        "occurredAt": "2026-11-20T14:00:00Z",
        "payload": {"requestId": req, "tenantId": "tenant-demo", "transcriptKey": f"transcripts/{req}.json"},
    }
    env.update(over)
    return json.dumps(env).encode()


def test_mensagem_valida():
    env = Envelope.parse(_msg())
    assert env.type == "CategorizationRequested"
    assert env.payload["transcriptKey"].startswith("transcripts/")


@pytest.mark.parametrize(
    "body",
    [
        b"isso nao e json",
        b"[1, 2, 3]",
        _msg(payload={"requestId": "nao-e-uuid"}),            # viola o schema do evento (F4)
        _msg(messageId="123"),                                  # messageId não é uuid
        json.dumps({"type": "CategorizationRequested"}).encode(),  # faltam campos do envelope
    ],
)
def test_mensagem_invalida_vai_para_dlq(body):
    with pytest.raises(InvalidMessage):
        Envelope.parse(body)


def test_tipo_desconhecido_valida_so_o_envelope():
    env = Envelope.parse(_msg(type="AudioReceived", payload={"qualquer": 1}))
    assert env.type == "AudioReceived"


def test_evento_publicado_respeita_o_contrato():
    req = str(uuid.uuid4())
    env = new_envelope("AudioCategorized", req, {"requestId": req, "category": "TECNICO", "priority": "HIGH", "confidence": 0.8})
    assert env["correlationId"] == req and env["version"] == 1


def test_evento_publicado_fora_do_contrato_falha():
    req = str(uuid.uuid4())
    with pytest.raises(Exception):
        new_envelope("AudioCategorized", req, {"requestId": req, "category": "TECNICO", "priority": "ALTISSIMA"})
