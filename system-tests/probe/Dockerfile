FROM python:3.11-slim@sha256:94c50be2dc994b873b55bc123e95e6dbade08095b3dfd790f51c34de3f08cbb7

WORKDIR /probe
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes --only-binary=:all: -r requirements.lock
COPY probe.py .

ENTRYPOINT ["python", "/probe/probe.py"]
