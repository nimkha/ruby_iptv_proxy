# Use an official Ruby runtime as a parent image
FROM ruby:3.1-slim

# Set the working directory in the container
WORKDIR /usr/src/app

# Install system dependencies that some gems might need (e.g., nokogiri)
RUN apt-get update -qq && apt-get install -y build-essential libxml2-dev libxslt1-dev

# Install Bundler
RUN gem install bundler

# Copy the Gemfile and Gemfile.lock into the container
COPY Gemfile Gemfile.lock ./

# Install project gems
RUN bundle install --jobs $(nproc) --retry 3

# Copy the rest of the application code into the container
COPY . .

# Make port 8000 available to the world outside this container
EXPOSE 8000

# Define the command to run the application
# Using Puma as the web server, configured via config.ru
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]

# Create a default puma config if it doesn't exist for simpler startup
# You can customize this file further if needed.
RUN mkdir -p config && \
    echo "port ENV.fetch('PORT', 8000)" > config/puma.rb && \
    echo "workers ENV.fetch('WEB_CONCURRENCY', 0)" >> config/puma.rb && \
    echo "threads_count = ENV.fetch('RAILS_MAX_THREADS', 5).to_i" >> config/puma.rb && \
    echo "threads threads_count, threads_count" >> config/puma.rb && \
    echo "preload_app!" >> config/puma.rb && \
    echo "environment ENV.fetch('RACK_ENV', 'production')" >> config/puma.rb
