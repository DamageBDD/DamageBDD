FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 ECAI_VIDEO_DATA=/data
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
WORKDIR /srv
COPY pyproject.toml ./
COPY ecai_video_fastpath ./ecai_video_fastpath
RUN pip install --no-cache-dir . && mkdir -p /data && chown -R 10001:10001 /data
USER 10001:10001
EXPOSE 9011
CMD ["uvicorn", "ecai_video_fastpath.api:app", "--host", "0.0.0.0", "--port", "9011", "--workers", "1"]
