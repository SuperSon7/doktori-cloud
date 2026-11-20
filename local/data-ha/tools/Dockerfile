ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}
WORKDIR /lab
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY probe.py .
ENTRYPOINT ["python", "/lab/probe.py"]
