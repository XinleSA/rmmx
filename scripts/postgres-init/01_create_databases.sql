-- =============================================================================
--  Xinle 欣乐 — PostgreSQL Database Initialization Script
-- =============================================================================
--  Author:        James Barrett | Company: Xinle, LLC
--  Version:       1.0.0
--  Created:       March 11, 2025
--  Last Modified: March 11, 2025
-- =============================================================================
--
--  This script runs automatically on first container startup via the
--  /docker-entrypoint-initdb.d/ mechanism in the official postgres image.
--
--  It creates the required databases for n8n and Forgejo if they do not
--  already exist. The root database (xinle_db) is created by the
--  POSTGRES_DB environment variable in docker-compose.yml.
-- =============================================================================

-- Create n8n database
SELECT 'CREATE DATABASE n8n OWNER ' || current_user
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec

-- Create forgejo database
SELECT 'CREATE DATABASE forgejo OWNER ' || current_user
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'forgejo')\gexec
