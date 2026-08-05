FROM python:3.11-slim

WORKDIR /probe
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY probe.py .

ENTRYPOINT ["python", "/probe/probe.py"]
