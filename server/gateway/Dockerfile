# Dawwen gateway: the same image runs on AWS Lambda (through Lambda Web Adapter) and anywhere Docker runs.
FROM public.ecr.aws/docker/library/python:3.12-slim-bookworm

# Turns Lambda invocations into plain HTTP for uvicorn; inert outside Lambda.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/healthz \
    AWS_LWA_INVOKE_MODE=response_stream \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /var/task
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# Lambda ignores USER and runs as its own sandbox user; this protects `docker run` at home.
RUN useradd --system --uid 10001 dawwen
USER 10001
EXPOSE 8080
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --no-access-log"]
