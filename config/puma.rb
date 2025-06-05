require 'fileutils'

# Puma can serve each request in a thread from an internal thread pool.
# The `threads`method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is 0, 5
threads_count = ENV.fetch("PUMA_MAX_THREADS") { 5 }.to_i # Use a more generic ENV var if preferred
threads threads_count, threads_count
 
# The port to listen on.
puma_port = ENV.fetch("PORT") { 8000 }.to_i
environment ENV.fetch("RACK_ENV") { "production" } # Default to production for Docker
app_dir = File.expand_path("../..", __FILE__) # Define the application directory
directory app_dir # Instruct Puma to change to this directory before starting

bind "tcp://0.0.0.0:#{puma_port}"

pids_dir = "#{app_dir}/tmp/pids"
FileUtils.mkdir_p(pids_dir) unless File.directory?(pids_dir)

# Specify where Puma stores its PID and state files:
pidfile "#{pids_dir}/puma.pid"
state_path "#{pids_dir}/puma.state"
activate_control_app # Default path is tmp/pids/pumactl.sock

# If your config.ru is not in the default location (the directory Puma is run from),
# you can specify it:
# rackup "#{app_dir}/config.ru"