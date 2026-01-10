#!/bin/bash
set -euo pipefail

# Only run in remote Claude Code environment
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

echo "=== Setting up vets-api development environment ==="

# ============================================================================
# Install system dependencies
# ============================================================================
echo "Installing system dependencies..."
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq libpq-dev pdftk-java postgresql-16-postgis-3 poppler-utils imagemagick tesseract-ocr tesseract-ocr-eng 2>/dev/null || true

# ============================================================================
# Configure PostgreSQL
# ============================================================================
echo "Configuring PostgreSQL..."
PG_DATA="/var/lib/postgresql/16/main"
PG_BIN="/usr/lib/postgresql/16/bin"

# Create socket directories
mkdir -p /var/run/postgresql /tmp
chown claude:ubuntu /var/run/postgresql 2>/dev/null || true

# Copy config files if missing
if [ ! -f "$PG_DATA/postgresql.conf" ]; then
  cp /usr/share/postgresql/16/postgresql.conf.sample "$PG_DATA/postgresql.conf"
  chown claude:ubuntu "$PG_DATA/postgresql.conf"
fi

if [ ! -f "$PG_DATA/pg_hba.conf" ] || ! grep -q "^local.*trust" "$PG_DATA/pg_hba.conf" 2>/dev/null; then
  cat > "$PG_DATA/pg_hba.conf" << 'HBAEOF'
# PostgreSQL Client Authentication Configuration File
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
HBAEOF
  chown claude:ubuntu "$PG_DATA/pg_hba.conf"
fi

if [ ! -f "$PG_DATA/pg_ident.conf" ]; then
  cp /usr/share/postgresql/16/pg_ident.conf.sample "$PG_DATA/pg_ident.conf"
  chown claude:ubuntu "$PG_DATA/pg_ident.conf"
fi

# Configure postgresql.auto.conf for socket directories
if ! grep -q "unix_socket_directories" "$PG_DATA/postgresql.auto.conf" 2>/dev/null; then
  cat >> "$PG_DATA/postgresql.auto.conf" << 'AUTOEOF'
listen_addresses = 'localhost'
port = 5432
unix_socket_directories = '/tmp,/var/run/postgresql'
AUTOEOF
fi

# Start PostgreSQL as claude user (cannot run as root)
if ! pg_isready -h localhost -q 2>/dev/null; then
  echo "Starting PostgreSQL..."
  su - claude -c "$PG_BIN/pg_ctl -D $PG_DATA -l /tmp/pg.log start" || true
  sleep 2
fi

# ============================================================================
# Start Redis
# ============================================================================
echo "Starting Redis..."
if ! redis-cli ping > /dev/null 2>&1; then
  redis-server --daemonize yes 2>/dev/null || true
  sleep 1
fi

# ============================================================================
# Create PostgreSQL users
# ============================================================================
echo "Creating PostgreSQL users..."
psql -h /tmp -U postgres -c "CREATE USER root WITH SUPERUSER CREATEDB;" 2>/dev/null || true
psql -h /tmp -U postgres -c "CREATE USER claude WITH SUPERUSER CREATEDB;" 2>/dev/null || true

# ============================================================================
# Create configuration files
# ============================================================================
echo "Creating configuration files..."
cd "$CLAUDE_PROJECT_DIR"

# Create certs directory
mkdir -p config/certs
touch config/certs/vetsgov-localhost.crt
touch config/certs/vetsgov-localhost.key

# Create settings.local.yml if it doesn't exist
if [ ! -f config/settings.local.yml ]; then
  cat > config/settings.local.yml << 'SETTINGSEOF'
saml:
  authn_requests_signed: false

clamav:
  mock: true
SETTINGSEOF
fi

# Create .developer-setup file for binstubs (use native mode)
if [ ! -f .developer-setup ]; then
  echo "native" > .developer-setup
fi

# ============================================================================
# Install Ruby dependencies
# ============================================================================
echo "Installing Ruby dependencies..."
gem install bundler:2.5.23 --no-document 2>/dev/null || true
/opt/rbenv/versions/3.3.6/bin/bundle _2.5.23_ install --jobs 4 2>&1 | tail -5 || true

# ============================================================================
# Setup database
# ============================================================================
echo "Setting up database..."
/opt/rbenv/versions/3.3.6/bin/bundle _2.5.23_ exec bin/rails db:create 2>/dev/null || true
/opt/rbenv/versions/3.3.6/bin/bundle _2.5.23_ exec bin/rails db:schema:load 2>/dev/null || true

# ============================================================================
# Set up PATH for the session
# ============================================================================
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="/opt/rbenv/versions/3.3.6/bin:/usr/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

echo "=== vets-api environment setup complete ==="
echo "Run 'bundle exec bin/rails server -b 0.0.0.0' to start the server"
