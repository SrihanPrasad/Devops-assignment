# The wheel is built *before* docker build (pipeline stage order) and copied
# into dist/. The image just installs it - the same artifact that goes to Nexus/JFrog.
FROM python:3.12-slim

RUN useradd --create-home app
WORKDIR /app
COPY dist/*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && rm /tmp/*.whl

USER app
ENV PORT=8000
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request,sys; urllib.request.urlopen('http://localhost:8000/health', timeout=2)" || exit 1
CMD ["sh", "-c", "gunicorn -b 0.0.0.0:${PORT} app.wsgi:app"]
