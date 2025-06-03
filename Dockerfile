# Use an official Ruby runtime as a parent image
FROM ruby:3.3-slim

# Set the working directory in the container
WORKDIR /usr/src/app

# Install dependencies for Nokogiri and other gems that might need native extensions
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libxml2-dev \
    libxslt1-dev \
    pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Copy the Gemfile and Gemfile.lock (or Gemfile.builder if it generates Gemfile.lock)
COPY Gemfile Gemfile.lock ./
# If you are using Gemfile.builder to generate Gemfile.lock, you might need:
# COPY Gemfile.builder ./

# Install gems
RUN bundle install --jobs $(nproc) --retry 3

# Copy the rest of the application code
COPY . .

# Expose port 8000 to the outside world
EXPOSE 8000

# The main command to run when the container starts
CMD ["bundle", "exec", "puma", "config.ru"]