# v41: Nordvik's tenant portal as a container. Built and published to ghcr.io by
# .github/workflows/v41-portal.yml.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py nordvik.py ./
COPY templates/ templates/
COPY static/ static/

# Its own user, with a home: gunicorn writes its control socket there.
RUN useradd --create-home --uid 10001 portal
USER portal
EXPOSE 8080
# Threaded workers: a thread receives a slow image upload while the worker keeps reporting in.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--worker-class", "gthread", "--workers", "2", "--threads", "4", "app:app"]
