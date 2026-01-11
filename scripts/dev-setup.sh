#!/bin/bash
# scripts/dev-setup.sh - Shared development environment setup for vets-api
# Used by: Claude Code, GitHub Copilot, and local development
#
# Usage:
#   ./scripts/dev-setup.sh [options]
#
# Options:
#   --skip-bundle    Skip bundle install
#   --skip-db        Skip database setup
#   --parallel-dbs   Create parallel test databases (for parallel_tests gem)
#
set -euo pipefail

SKIP_BUNDLE=false
SKIP_DB=false
PARALLEL_DBS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-bundle) SKIP_BUNDLE=true; shift ;;
    --skip-db) SKIP_DB=true; shift ;;
    --parallel-dbs) PARALLEL_DBS=true; shift ;;
    *) shift ;;
  esac
done

echo "=== Setting up vets-api development environment ==="

# ============================================================================
# Detect environment
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Detect if we're in a container/CI environment
IS_ROOT=$([ "$(id -u)" -eq 0 ] && echo true || echo false)
IS_CLAUDE=${CLAUDE_CODE_REMOTE:-false}
IS_CODESPACE=${CODESPACES:-false}
IS_GITHUB_ACTIONS=${GITHUB_ACTIONS:-false}

echo "Environment: root=$IS_ROOT, claude=$IS_CLAUDE, codespace=$IS_CODESPACE, gha=$IS_GITHUB_ACTIONS"

# ============================================================================
# Install system dependencies
# ============================================================================
install_system_deps() {
  echo "Installing system dependencies..."

  if command -v apt-get &> /dev/null; then
    if [ "$IS_ROOT" = true ]; then
      apt-get update -qq 2>/dev/null || true
      apt-get install -y -qq \
        libpq-dev \
        pdftk-java \
        poppler-utils \
        imagemagick \
        tesseract-ocr \
        tesseract-ocr-eng \
        redis-server \
        2>/dev/null || true

      # Install PostgreSQL 16 with PostGIS if not present
      if ! command -v psql &> /dev/null; then
        apt-get install -y -qq postgresql-16 postgresql-16-postgis-3 2>/dev/null || true
      fi
    else
      echo "Skipping apt-get (not root). Ensure dependencies are installed."
    fi
  fi
}

# ============================================================================
# Configure and start PostgreSQL
# ============================================================================
setup_postgresql() {
  echo "Setting up PostgreSQL..."

  # Find PostgreSQL version and paths
  PG_VERSION=""
  for v in 16 15 14; do
    if [ -d "/usr/lib/postgresql/$v" ]; then
      PG_VERSION=$v
      break
    fi
  done

  if [ -z "$PG_VERSION" ]; then
    echo "PostgreSQL not found. Please install PostgreSQL 14, 15, or 16."
    return 1
  fi

  PG_BIN="/usr/lib/postgresql/$PG_VERSION/bin"
  PG_DATA="/var/lib/postgresql/$PG_VERSION/main"

  # Configure pg_hba.conf for trust authentication
  if [ "$IS_ROOT" = true ] && [ -f "$PG_DATA/pg_hba.conf" ]; then
    if ! grep -q "^local.*all.*all.*trust" "$PG_DATA/pg_hba.conf" 2>/dev/null; then
      cat > "$PG_DATA/pg_hba.conf" << 'HBAEOF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
HBAEOF
    fi
  fi

  # Start PostgreSQL
  if ! pg_isready -q 2>/dev/null; then
    echo "Starting PostgreSQL..."
    if [ "$IS_ROOT" = true ]; then
      service postgresql start 2>/dev/null || \
        su - postgres -c "$PG_BIN/pg_ctl -D $PG_DATA start" 2>/dev/null || true
    else
      pg_ctlcluster $PG_VERSION main start 2>/dev/null || true
    fi
    sleep 2
  fi

  # Create users
  echo "Creating PostgreSQL users..."
  local PG_USER=${SUDO_USER:-${USER:-postgres}}
  psql -U postgres -c "CREATE USER root WITH SUPERUSER CREATEDB;" 2>/dev/null || true
  psql -U postgres -c "CREATE USER $PG_USER WITH SUPERUSER CREATEDB;" 2>/dev/null || true
  psql -U postgres -c "CREATE USER runner WITH SUPERUSER CREATEDB;" 2>/dev/null || true
}

# ============================================================================
# Start Redis
# ============================================================================
setup_redis() {
  echo "Setting up Redis..."

  if ! redis-cli ping > /dev/null 2>&1; then
    if [ "$IS_ROOT" = true ]; then
      service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
    else
      redis-server --daemonize yes 2>/dev/null || true
    fi
    sleep 1
  fi

  if redis-cli ping > /dev/null 2>&1; then
    echo "Redis is running"
  else
    echo "Warning: Redis may not be running"
  fi
}

# ============================================================================
# Create configuration files
# ============================================================================
setup_config_files() {
  echo "Creating configuration files..."

  # Create certs directory
  mkdir -p config/certs config/betamocks/certs
  touch config/certs/vetsgov-localhost.crt
  touch config/certs/vetsgov-localhost.key
  touch config/betamocks/certs/vetsgov-localhost.crt
  touch config/betamocks/certs/vetsgov-localhost.key

  # Create settings.local.yml if it doesn't exist
  if [ ! -f config/settings.local.yml ]; then
    cat > config/settings.local.yml << 'SETTINGSEOF'
saml:
  authn_requests_signed: false

clamav:
  mock: true
  host: '0.0.0.0'
  port: '33100'
SETTINGSEOF
  fi

  # Create .developer-setup file
  if [ ! -f .developer-setup ]; then
    echo "native" > .developer-setup
  fi
}

# ============================================================================
# Install Ruby dependencies
# ============================================================================
install_ruby_deps() {
  if [ "$SKIP_BUNDLE" = true ]; then
    echo "Skipping bundle install (--skip-bundle)"
    return 0
  fi

  echo "Installing Ruby dependencies..."

  # Find Ruby/Bundler
  if command -v bundle &> /dev/null; then
    BUNDLE_CMD="bundle"
  elif [ -x "/opt/rbenv/versions/3.3.6/bin/bundle" ]; then
    BUNDLE_CMD="/opt/rbenv/versions/3.3.6/bin/bundle"
  else
    gem install bundler:2.5.23 --no-document 2>/dev/null || true
    BUNDLE_CMD="bundle"
  fi

  $BUNDLE_CMD config set frozen false 2>/dev/null || true
  $BUNDLE_CMD install --jobs 4 2>&1 | tail -10 || true
}

# ============================================================================
# Setup database
# ============================================================================
setup_database() {
  if [ "$SKIP_DB" = true ]; then
    echo "Skipping database setup (--skip-db)"
    return 0
  fi

  echo "Setting up database..."

  # Find rails command
  if [ -x "bin/rails" ]; then
    RAILS_CMD="bundle exec bin/rails"
  else
    RAILS_CMD="bundle exec rails"
  fi

  # Create and setup databases
  RAILS_ENV=development $RAILS_CMD db:create 2>/dev/null || true
  RAILS_ENV=development $RAILS_CMD db:schema:load 2>/dev/null || $RAILS_CMD db:migrate 2>/dev/null || true

  RAILS_ENV=test $RAILS_CMD db:create 2>/dev/null || true
  RAILS_ENV=test $RAILS_CMD db:schema:load 2>/dev/null || true

  # Create parallel test databases if requested
  if [ "$PARALLEL_DBS" = true ]; then
    echo "Creating parallel test databases..."
    for i in 2 3 4 5 6 7 8; do
      psql -U postgres -c "DROP DATABASE IF EXISTS \"vets-api-test$i\";" 2>/dev/null || true
      psql -U postgres -c "CREATE DATABASE \"vets-api-test$i\" WITH TEMPLATE \"vets-api-test\" OWNER postgres;" 2>/dev/null || true
      psql -U postgres -c "DROP DATABASE IF EXISTS \"vets_api_audit_test$i\";" 2>/dev/null || true
      psql -U postgres -c "CREATE DATABASE \"vets_api_audit_test$i\" WITH TEMPLATE \"vets_api_audit_test\" OWNER postgres;" 2>/dev/null || true
    done
  fi
}

# ============================================================================
# Main
# ============================================================================
install_system_deps
setup_postgresql
setup_redis
setup_config_files
install_ruby_deps
setup_database

echo ""
echo "=== vets-api environment setup complete ==="
echo ""
echo "Available commands:"
echo "  bundle exec bin/rails server -b 0.0.0.0    # Start server"
echo "  bundle exec bin/rspec spec/path/to_spec.rb # Run specific test"
echo "  bundle exec parallel_test spec modules -n 8 --type rspec  # Parallel tests"
echo ""
