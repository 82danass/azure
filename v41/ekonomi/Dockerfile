# v41: Nordvik's finance site as a container. Built and published to ghcr.io by
# .github/workflows/v41-ekonomi.yml.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py cost.py ./
COPY templates/ templates/
COPY static/ static/

# Its own user, with a home: gunicorn writes its control socket there.
RUN useradd --create-home --uid 10001 ekonomi
USER ekonomi
EXPOSE 8080
# One process, so the five-minute cost cache is one cache: Cost Management throttles per scope.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--worker-class", "gthread", "--workers", "1", "--threads", "8", "app:app"]
