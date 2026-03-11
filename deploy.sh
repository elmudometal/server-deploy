#!/bin/bash
set -e  # Detener script si ocurre cualquier error

APP_DIR="/var/www/app"
RELEASE=$(date +%Y%m%d%H%M%S)
RELEASE_DIR="$APP_DIR/releases/$RELEASE"
CURRENT_LINK="$APP_DIR/current"

# Evitar despliegues concurrentes mediante lock file
LOCK_FILE="$APP_DIR/deploy.lock"
if [ -e "$LOCK_FILE" ]; then
  echo "Ya hay un despliegue en progreso. Abortando."
  exit 1
fi
touch "$LOCK_FILE"

# Obtener release anterior para posible rollback
if [ -L "$CURRENT_LINK" ]; then
    PREV_REL=$(readlink "$CURRENT_LINK" | xargs basename)
else
    PREV_REL=""
fi

echo ">>> Iniciando deploy. Release nueva: $RELEASE"
mkdir -p "$RELEASE_DIR"
cd "$RELEASE_DIR"

# Clonar repositorio (solo este release)
echo "- Clonando repositorio en $RELEASE_DIR..."
git clone --depth 1 --branch main git@github.com:ORG/REPO.git ./
rm -rf .git

# Instalar dependencias PHP
echo "- Instalar dependencias Composer..."
composer install --no-dev --optimize-autoloader --no-interaction

# (Opcional) Build de assets front-end
if [ -f "package.json" ]; then
  echo "- Instalando y compilando assets (npm)..."
  npm ci --silent
  npm run build
  rm -rf node_modules
fi

# Enlazar recursos compartidos
echo "- Enlazando recursos compartidos (.env, storage)..."
ln -s "$APP_DIR/shared/.env" .env
rm -rf storage
ln -s "$APP_DIR/shared/storage" storage

# Optimizar Laravel
echo "- Cacheo de configuración y rutas..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Ejecutar migraciones de forma forzada
echo "- Ejecutando migraciones en BD..."
if ! php artisan migrate --force; then
    echo "ERROR: Las migraciones fallaron. Revirtiendo."
    rm -rf "$RELEASE_DIR"
    rm -f "$LOCK_FILE"
    exit 1
fi

# Cambio de symlink CURRENT (deploy sin downtime)
echo "- Activando nueva release..."
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# Reiniciar colas (para nuevos jobs)
echo "- Reiniciando workers de queue..."
php artisan queue:restart

# Comprobar estado de salud (healthcheck HTTP)
echo "- Verificando healthcheck..."
if ! curl -fsSL http://localhost/health; then
    echo "ERROR: Healthcheck falló. Haciendo rollback..."
    if [ -n "$PREV_REL" ]; then
        ln -sfn "$APP_DIR/releases/$PREV_REL" "$CURRENT_LINK"
        echo "- Rollback a la release anterior ($PREV_REL) completo."
    fi
    rm -rf "$RELEASE_DIR"
    rm -f "$LOCK_FILE"
    exit 1
fi

echo ">>> Deploy de la release $RELEASE completado con éxito."
rm -f "$LOCK_FILE"
