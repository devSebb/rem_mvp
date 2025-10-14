#!/usr/bin/env bash
set -o errexit

echo "Starting build process..."

# Install dependencies
echo "Installing Ruby dependencies..."
bundle install

# Install Node.js dependencies
echo "Installing Node.js dependencies..."
yarn install

# Precompile assets
echo "Precompiling assets..."
bundle exec rake assets:precompile

# Clean up old assets
echo "Cleaning up old assets..."
bundle exec rake assets:clean

# Run database migrations
echo "Running database migrations..."
bundle exec rake db:migrate

echo "Build completed successfully!"
