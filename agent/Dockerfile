FROM python:3.13-slim
WORKDIR /srv
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" psutil tinytuya flux_led
COPY app ./app
EXPOSE 8787
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787"]
