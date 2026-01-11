# CLAUDE.md - Vets-API Development Guide

This document provides essential information for working with the vets-api codebase.

## Project Overview

Vets-API is a Ruby on Rails 7.2.3 API application (Ruby 3.3.6) that serves as the backend for VA.gov. It integrates with numerous VA systems including BGS (Benefits Gateway Services), MPI, Lighthouse, and others.

## Prerequisites

### System Dependencies

```bash
apt-get install -y libpq-dev pdftk-java postgresql-16-postgis-3 \
  poppler-utils imagemagick tesseract-ocr tesseract-ocr-eng
```

### Services

- **PostgreSQL 16** with PostGIS extension
- **Redis** for caching and Sidekiq

### Sidekiq Enterprise

Requires credentials for enterprise gems:
```bash
export BUNDLE_ENTERPRISE__CONTRIBSYS__COM=<credentials>
bundle install
```

## Running Tests

### Single-threaded (slower, ~25 minutes)

```bash
RAILS_ENV=test bundle exec bin/rspec
```

### Parallel Tests (faster, ~10-15 minutes)

The project uses `parallel_tests` gem. Run both `spec` and `modules` directories:

```bash
# With 8 processes (adjust based on available cores and databases)
bundle exec parallel_test spec modules --group-by filesize --type rspec -n 8
```

**Note:** Parallel tests require multiple test databases. Create them with:
```bash
# For processes 2-8 (process 1 uses the base test database)
for i in 2 3 4 5 6 7 8; do
  psql -U root -d postgres -c "CREATE DATABASE \"vets-api-test$i\" WITH TEMPLATE \"vets-api-test\" OWNER root;"
  psql -U root -d postgres -c "CREATE DATABASE \"vets_api_audit_test$i\" WITH TEMPLATE \"vets_api_audit_test\" OWNER root;"
done
```

### Running Specific Tests

```bash
# Single file
RAILS_ENV=test bundle exec bin/rspec spec/path/to/spec.rb

# Single example by line number
RAILS_ENV=test bundle exec bin/rspec spec/path/to/spec.rb:123

# With specific seed (for reproducing order-dependent failures)
RAILS_ENV=test bundle exec bin/rspec --seed 12345
```

## Common Test Issues

### Waterdrop/Kafka Logger Interference

Tests that expect specific `Rails.logger.error` calls can fail when Waterdrop (Kafka client) also logs errors.

**Fix:** Use `allow/have_received` pattern instead of `expect/to receive`:

```ruby
# Instead of this (strict, fails if other errors logged):
expect(Rails.logger).to receive(:error).with('Expected message')
do_something()

# Use this (flexible, verifies message was logged among all calls):
allow(Rails.logger).to receive(:error)
do_something()
expect(Rails.logger).to have_received(:error).with('Expected message')
```

### Memoized Instance Variables

Classes that memoize Redis or other connections can cause test pollution.

**Fix:** Reset instance variables in `before` block:

```ruby
before do
  described_class.instance_variable_set(:@redis, nil)
  allow(Redis::Namespace).to receive(:new).and_return(redis_double)
end
```

### BGS Service Error Handling

BGS service methods should explicitly return `nil` on error, not the result of logging:

```ruby
def find_regional_offices
  service.share_data.find_regional_offices[:return]
rescue => e
  notify_of_service_exception(e, __method__, 1, :warn)
  nil  # Explicit return required!
end
```

### Rack::Attack Rate Limiting Tests

Rate limiting tests need:
1. Proper IP headers (`X-Real-Ip` not just `REMOTE_ADDR`)
2. Mocked API clients to ensure consistent responses

## Key Directories

```
spec/                    # Main test directory
modules/                 # Rails engines with their own specs
  */spec/               # Engine-specific tests
config/initializers/    # App initialization (BGS, Redis, etc.)
lib/                    # Shared libraries (BGS, BGSV2 services)
app/controllers/        # API controllers
```

## Database Setup

```bash
# Create databases
RAILS_ENV=test bundle exec bin/rails db:create

# Load schema
RAILS_ENV=test bundle exec bin/rails db:schema:load

# Or reset (drop, create, load schema)
RAILS_ENV=test bundle exec bin/rails db:reset
```

## Starting the Server

```bash
bundle exec bin/rails server -b 0.0.0.0 -p 3000
```

## Environment Variables

Key environment variables:
- `RAILS_ENV` - test, development, production
- `BUNDLE_ENTERPRISE__CONTRIBSYS__COM` - Sidekiq Enterprise credentials
- `TEST_ENV_NUMBER` - Used by parallel_tests for database selection
- `NOCOVERAGE=true` - Skip SimpleCov for faster test runs

## CI/GitHub Actions

The project runs parallel tests in CI with:
```bash
bundle exec parallel_test spec modules --group-by filesize --type rspec -n 24
```

See `.github/workflows/code_checks.yml` for full CI configuration.
