require 'httparty'
require 'concurrent-ruby'
require 'thread' # For Mutex

class StreamChecker
  def initialize(config, log_info_method, log_warn_method, log_debug_method, log_error_method)
    @config = config
    @stream_groups = {}
    @current_index = {}
    @lock = Mutex.new

    # Store logger methods
    @log_info = log_info_method
    @log_warn = log_warn_method
    @log_debug = log_debug_method
    @log_error = log_error_method

    load_stream_groups
  end

  attr_reader :config # Allow app.rb to read config for EPG mapping

  def load_stream_groups
    @lock.synchronize do
      @config["channels"].each do |name, urls|
        @stream_groups[name] = urls
        @current_index[name] ||= 0
      end
    end
  end

  def get_active_streams
    groups_to_process = {}
    @lock.synchronize do
      @stream_groups.each do |group_name, entries|
        next if entries.nil? || entries.empty?
        current_idx_val = @current_index[group_name] || 0
        start_index = (0 <= current_idx_val && current_idx_val < entries.length) ? current_idx_val : 0
        if start_index != current_idx_val
            @log_debug.call("Corrected start_index for group '#{group_name}' from #{current_idx_val} to #{start_index}.")
        end
        groups_to_process[group_name] = {
          "entries" => entries.dup, # Shallow copy
          "start_index" => start_index,
          "num_entries" => entries.length
        }
      end
    end

    if groups_to_process.empty?
      @log_info.call("[StreamChecker] No groups to process in get_active_streams (either @stream_groups is empty or all groups have empty entry lists).")
      return {}
    end


    active_working_streams = {}
    max_workers_for_check = 10 # Adjust as needed

    future_to_info = {}
    group_check_results = Hash.new { |h, k| h[k] = Array.new(groups_to_process[k]["num_entries"], false) }

    pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: max_workers_for_check,
      max_queue: max_workers_for_check * 2, # Or some other sensible value
      fallback_policy: :caller_runs # If queue is full, submitting thread runs task
    )

    groups_to_process.each do |group_name, group_data|
      group_data["entries"].each_with_index do |entry, original_idx|
        future = pool.post do
          _is_stream_working(entry)
        end
        future_to_info[future] = { group_name: group_name, original_idx: original_idx, entry: entry }
      end
    end
    pool.shutdown # Signal that no more tasks will be submitted
    pool.wait_for_termination # Wait for all tasks to complete

    future_to_info.each do |future, info|
      group_name = info[:group_name]
      original_idx = info[:original_idx]
      entry_for_log = info[:entry]
      begin
        is_working = future.value # Get result from completed future
        group_check_results[group_name][original_idx] = is_working if is_working != nil # future.value can be nil if task raised error and wasn't caught
        @log_debug.call("Parallel check: Stream #{entry_for_log['url']} for group '#{group_name}' (idx #{original_idx}) is working.") if is_working
      rescue StandardError => exc # Catch errors from the future's execution
        @log_error.call("Exception during parallel check for stream #{entry_for_log['url'] || 'N/A'} in group #{group_name}: #{exc}")
        group_check_results[group_name][original_idx] = false # Ensure it's marked as not working
      end
    end
    
    new_current_indices = {}
    groups_to_process.each do |group_name, group_data|
      entries = group_data["entries"]
      start_index = group_data["start_index"]
      num_entries = group_data["num_entries"]
      results_for_group = group_check_results[group_name]

      chosen_stream_entry = nil
      chosen_stream_original_index = -1

      num_entries.times do |i|
        idx_to_try = (start_index + i) % num_entries
        if results_for_group[idx_to_try]
          chosen_stream_entry = entries[idx_to_try]
          chosen_stream_original_index = idx_to_try
          break
        end
      end

      if chosen_stream_entry
        @log_info.call("Selected working stream for group '#{group_name}': #{chosen_stream_entry['url']} (original index #{chosen_stream_original_index}) after parallel checks.")
        active_working_streams[group_name] = chosen_stream_entry
        new_current_indices[group_name] = chosen_stream_original_index
      else
        @log_warn.call("No working streams found for channel group '#{group_name}' after checking all #{num_entries} streams in parallel. Group will be omitted from playlist.")
      end
    end

    if !new_current_indices.empty?
      @lock.synchronize do
        new_current_indices.each do |group_name, new_idx|
          @current_index[group_name] = new_idx if @stream_groups.key?(group_name)
        end
      end
    end
    active_working_streams
  end

  def mark_stream_failed(channel_name)
    @lock.synchronize do
      return unless @stream_groups.key?(channel_name)
      current = @current_index[channel_name] || 0
      total = @stream_groups[channel_name].length
      if total > 0
        @current_index[channel_name] = (current + 1) % total
        @log_info.call("[FAILOVER] #{channel_name} -> Switched to index #{@current_index[channel_name]}")
      else
        @log_warn.call("[FAILOVER] Attempted to failover channel #{channel_name}, but it has no streams.")
      end
    end
  end

  def update_config(new_app_config)
    @lock.synchronize do
      @config = new_app_config
      new_stream_groups = {}
      old_current_index = @current_index.dup
      @current_index = {}

      (@config["channels"] || {}).each do |group_name, entries_list|
        new_stream_groups[group_name] = entries_list
        if old_current_index.key?(group_name) && old_current_index[group_name] < entries_list.length
          @current_index[group_name] = old_current_index[group_name]
        else
          @current_index[group_name] = 0
        end
      end
      @stream_groups = new_stream_groups
      @log_info.call("StreamChecker configuration updated.")
    end
  end

  def background_monitor(interval = 60)
    loop do
      @log_info.call("[Monitor] Starting background check of default streams...")
      streams_to_check_in_monitor = {}
      @lock.synchronize do
        @stream_groups.each do |channel_group_name, entries|
          next if entries.nil? || entries.empty?
          idx = @current_index[channel_group_name] || 0
          idx = 0 if idx >= entries.length # Safety check
          streams_to_check_in_monitor[channel_group_name] = entries[idx]
        end
      end

      streams_to_check_in_monitor.each do |channel, entry|
        unless _is_stream_working(entry)
          @log_warn.call("[Monitor] Default stream for #{channel} failed (URL: #{entry['url']}). Advancing index via mark_stream_failed...")
          mark_stream_failed(channel)
        end
      end
      sleep interval
    end
  end

  private

  def _is_stream_working(entry)
    url = entry.is_a?(Hash) ? entry['url'] : entry
    return false if url.nil? || url.empty?

    headers = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    begin
      # HTTParty.get can raise various errors for network issues
      response = HTTParty.get(url, headers: headers, timeout: 10, stream_body: true, follow_redirects: true) # stream_body to not load full content
      if [200, 301, 302].include?(response.code)
        return true
      else
        @log_debug.call("Stream check for URL #{url} returned non-OK status: #{response.code}")
        return false
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      @log_debug.call("Stream check timed out for URL #{url} (10s)")
      return false
    rescue StandardError => e # Catch other HTTParty/network errors
      @log_debug.call("Stream check failed for URL #{url} with exception: #{e.class} - #{e.message}")
      return false
    end
  end
end
