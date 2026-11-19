# O modelo Whisper é baixado NO BUILD e embutido na imagem (as réplicas não baixam nada ao subir).
#   --build-arg WHISPER_MODEL=small   troca o modelo (tiny | base | small | medium)

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

ARG WHISPER_MODEL=base
ENV WHISPER_MODEL=${WHISPER_MODEL} WHISPER_MODELS_DIR=/models
RUN python -c "from faster_whisper import WhisperModel; WhisperModel('${WHISPER_MODEL}', device='cpu', compute_type='int8', download_root='/models')"
ENV HF_HUB_OFFLINE=1

COPY contracts ./contracts
COPY migrations ./migrations
COPY transcription_worker ./transcription_worker

RUN useradd --system --uid 10001 --no-create-home app
USER app

ENV SCHEMAS_DIR=/app/contracts MIGRATIONS_DIR=/app/migrations HTTP_PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)" || exit 1

CMD ["python", "-m", "transcription_worker"]
