FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# スクリプトは Workflow YAML の source: フィールドにインラインで記述するため
# このイメージは python + kubernetes パッケージを提供するだけ
