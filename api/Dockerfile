# Image de l'API et du seed (contexte de build = racine du dépôt, pour
# pouvoir embarquer le script Lua du lot 2 sans le dupliquer).
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CART_LUA_PATH=/app/lua/cart_add.lua

WORKDIR /app

COPY api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY lot2-panier-sessions-redis/cart_add.lua ./lua/cart_add.lua
COPY api/app ./app
COPY api/seed.py .

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
