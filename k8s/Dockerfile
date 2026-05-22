# ── Stage 1: frontend build ───────────────────────────────────────────────────
# frontend/app.jsx is the editable React source. This stage compiles it into
# frontend/app.js so the browser never needs Babel or text/babel at runtime.
FROM node:20-bookworm-slim AS frontend-builder

WORKDIR /build

COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY frontend/ ./frontend/
RUN npm run build:frontend && \
    test -s frontend/app.js && \
    rm -f frontend/app.jsx

# ── Stage 2: Python dependency build ──────────────────────────────────────────
# Install dependencies in a separate stage so they do not need to be rebuilt
# every time frontend-only application code changes.
FROM python:3.12-slim AS python-builder

WORKDIR /build

COPY requirements.txt .

RUN python -m venv /build/venv && \
    /build/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    /build/venv/bin/pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY otp_relay/ ./otp_relay/

# ── Stage 3: runtime ──────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Create a non-root user — the container should not run as root.
RUN useradd --system --uid 999 --no-create-home --shell /usr/sbin/nologin otprelay

WORKDIR /app

# Copy venv, backend code, and built frontend only.
COPY --from=python-builder /build/venv ./venv
COPY --from=python-builder /build/main.py .
COPY --from=python-builder /build/otp_relay ./otp_relay
COPY --from=frontend-builder /build/frontend ./frontend

# Defense-in-depth: the runtime image should serve app.js, not app.jsx.
RUN test -s /app/frontend/app.js && \
    test ! -e /app/frontend/app.jsx && \
    test -d /app/otp_relay && \
    mkdir -p /app/data && \
    chown otprelay:otprelay /app/data

USER otprelay

EXPOSE 8000

# Use python -m uvicorn instead of the venv script directly.
# The uvicorn script in venv/bin/ has a hardcoded shebang pointing to the
# builder stage path (/build/venv/bin/python), which does not exist at runtime.
# Calling via python -m uvicorn bypasses the script entirely.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /app/venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')"

CMD ["/app/venv/bin/python", "-m", "uvicorn", "main:app", \
    "--host", "0.0.0.0", \
    "--port", "8000", \
    "--workers", "1"]
