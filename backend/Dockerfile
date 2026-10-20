FROM postgres:17.4-bookworm
ENTRYPOINT []
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd -m -u 10001 companion && mkdir /files /backups && chown companion /files /backups
COPY . .
USER companion
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
