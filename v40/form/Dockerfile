# v40: the ticket form as a container. The same form.py and page v39's web
# machine ran behind nginx and gunicorn; here the service serves the page too.
# Built and published to ghcr.io by .github/workflows/v40-form.yml.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY form.py .
COPY public/ public/

# Nothing in the image is written at run time.
USER nobody
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "60", "form:app"]
