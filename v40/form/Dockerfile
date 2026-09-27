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

# Its own user, with a home: gunicorn writes its control socket there.
RUN useradd --create-home --uid 10001 form
USER form
EXPOSE 8080
# Threaded workers: a thread receives a slow upload while the worker keeps
# reporting in, so an attachment arriving over a slow line is not cut off.
# In v39 nginx took the whole upload before gunicorn saw it; here nothing does.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--worker-class", "gthread", "--workers", "2", "--threads", "4", "form:app"]
