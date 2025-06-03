# Puma can serve each request in a thread from an internal thread pool.
# The `threads`method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is 0, 5
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count
 
# The port to listen on.
puma_port = ENV.fetch("PORT") { 8000 }
environment ENV.fetch("RACK_ENV") { "development" }
app_dir = File.expand_path("../..", __FILE__) # Define the application directory
directory app_dir # Instruct Puma to change to this directory before starting

bind "tcp://0.0.0.0:#{puma_port}"

# You might also want to specify where Puma stores its PID and state files:
# pidfile "#{app_dir}/tmp/pids/puma.pid"
# state_path "#{app_dir}/tmp/pids/puma.state"

# If your config.ru is not in the default location (the directory Puma is run from),
# you can specify it:
# rackup "#{app_dir}/config.ru"