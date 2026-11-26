FROM python:3.12-slim-bookworm AS dependencies

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY app/requirements.txt ./requirements.txt
RUN python -m pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/usr/local/bin:$PATH \
    APP_ENV=production \
    ENABLE_API_DOCS=false

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /nonexistent \
        --no-create-home --shell /usr/sbin/nologin app

COPY --from=dependencies /install /usr/local
WORKDIR /srv/app
COPY --chown=10001:10001 app/main.py ./main.py

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "from urllib.request import urlopen; urlopen('http://127.0.0.1:8000/readyz', timeout=2)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers"]
