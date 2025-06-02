require 'httparty'
require 'concurrent-ruby'
require 'thread' # For Mutex

class StreamChecker
  def initialize(config, log_info_method, log_warn_method, log_debug_method, log_error_method)
    @config = config
    @stream_groups = {}
    @current_index = {}
    @lock = Mutex.new

    @cache_lock = Mutex.new
    @cached_active_streams = {}
    @last_cache_update_time = Time.at(0) # Initialize to a very old time
    @cache_ttl = 300 # Cache Time-To-Live in seconds (e.g., 5 minutes)
    @full_check_lock = Mutex.new
    @full_check_running_flag = false

    # Store logger methods
    @log_info = log_info_method
    @log_warn = log_warn_method
    @log_debug = log_debug_method
    @log_error = log_error_method

    # Initial optimistic population and trigger async full check
    _update_internal_structures_and_optimistic_cache
    trigger_asynchronous_full_check
  end

  attr_reader :config # Allow app.rb to read config for EPG mapping

  def get_active_streams
    @cache_lock.synchronize do
      # Serve from cache if it's fresh and not empty
      if Time.now - @last_cache_update_time < @cache_ttl && !@cached_active_streams.empty?
        @log_info.call("[StreamChecker] Serving playlist from cache.")
        return @cached_active_streams.dup # Return a copy to prevent external modification
      end
    end
    # If cache is stale or empty, perform the checks and update the cache
    _perform_stream_checks_and_update_cache
  end

  def _perform_stream_checks_and_update_cache
    can_run_check = false
    @full_check_lock.synchronize do
      if !@full_check_running_flag
        @full_check_running_flag = true
        can_run_check = true
        @log_info.call("[StreamChecker] Starting full stream check and cache update process.")
      else
        @log_info.call("[StreamChecker] Full check already in progress. Call to _perform_stream_checks_and_update_cache skipped.")
      end
    end

    # If a check is already running, return the current cache (it might be optimistic or the result of the last completed check)
    return @cached_active_streams.dup unless can_run_check

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
    max_workers_for_check = 3 # Reduced from 10 to be gentler on providers

    # Store future objects along with info needed to process their results
    futures_info = []
    group_check_results = Hash.new { |h, k| h[k] = Array.new(groups_to_process[k]["num_entries"], false) }

    pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: max_workers_for_check,
      fallback_policy: :caller_runs # If queue is full, submitting thread runs task
    )

    groups_to_process.each do |group_name, group_data|
      group_data["entries"].each_with_index do |entry, original_idx|
        future = pool.post do
          _is_stream_working(entry)
        end
        futures_info << {
          future: future,
          group_name: group_name,
          original_idx: original_idx,
          entry_url: entry['url'] # For logging
        }
      end
    end
    pool.shutdown # Signal that no more tasks will be submitted
    pool.wait_for_termination # Wait for all tasks to complete

    futures_info.each do |f_info|
      group_name = f_info[:group_name]
      original_idx = f_info[:original_idx]
      entry_url_for_log = f_info[:entry_url]
      begin
        is_working = f_info[:future].value # Get result from completed future (true, false, or raises error)
        group_check_results[group_name][original_idx] = is_working
        @log_debug.call("Parallel check: Stream #{entry_url_for_log} for group '#{group_name}' (idx #{original_idx}) is working.") if is_working
      rescue StandardError => exc # Catch errors from the future's execution
        @log_error.call("Exception during parallel check for stream #{entry_url_for_log || 'N/A'} in group #{group_name}: #{exc.class} - #{exc.message}")
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

    @cache_lock.synchronize do
      @cached_active_streams = active_working_streams.dup
      @last_cache_update_time = Time.now
      @log_info.call("[StreamChecker] Playlist cache updated after performing checks.")
    end

    # Ensure the flag is reset regardless of how the method exits
    @full_check_lock.synchronize do
      @full_check_running_flag = false
      @log_info.call("[StreamChecker] Full stream check and cache update process finished.")
    end
    return @cached_active_streams.dup # Return a copy
  end

  def mark_stream_failed(channel_name)
    made_change = false
    @lock.synchronize do
      return unless @stream_groups.key?(channel_name)
      return if @stream_groups[channel_name].nil? || @stream_groups[channel_name].empty?
      current = @current_index[channel_name] || 0
      total = @stream_groups[channel_name].length
      if total > 0
        @current_index[channel_name] = (current + 1) % total
        @log_info.call("[FAILOVER] #{channel_name} -> Switched to index #{@current_index[channel_name]}")
        invalidate_cache # Invalidate cache as the active stream might change
        made_change = true
      else
        @log_warn.call("[FAILOVER] Attempted to failover channel #{channel_name}, but it has no streams.")
      end
    end
  end

  def update_config(new_app_config)
    @lock.synchronize do # Protect @config write
      @config = new_app_config
    end
    _update_internal_structures_and_optimistic_cache
    trigger_asynchronous_full_check # This will also invalidate and then rebuild the cache with actual checks
    @log_info.call("[StreamChecker] Configuration updated. Optimistic cache populated. Async full check triggered.")
  end
  def invalidate_cache
    @cache_lock.synchronize do
      @cached_active_streams = {}
      @last_cache_update_time = Time.at(0) # Mark as very old
      @log_info.call("[StreamChecker] Playlist cache invalidated.")
    end
  end

  # New private method to handle the logic shared by initialize and update_config
  private def _update_internal_structures_and_optimistic_cache
    new_stream_groups = {}
    new_current_index = {}
    optimistic_streams_for_cache = {}

    @lock.synchronize do # Protect access to @config and modification of internal structures
      old_current_index_snapshot = @current_index.dup # Snapshot before clearing

      (@config["channels"] || {}).each do |group_name, entries_list|
        next if entries_list.nil? || entries_list.empty?

        new_stream_groups[group_name] = entries_list
        
        # Preserve old index if valid for the new list, otherwise default to 0
        idx = old_current_index_snapshot[group_name] || 0
        idx = 0 if idx >= entries_list.length || idx < 0
        new_current_index[group_name] = idx
        
        optimistic_streams_for_cache[group_name] = entries_list[idx] if entries_list[idx]
      end
      
      @stream_groups = new_stream_groups
      @current_index = new_current_index
    end

    @cache_lock.synchronize do
      @cached_active_streams = optimistic_streams_for_cache
      @last_cache_update_time = Time.now # Mark optimistic cache as fresh
      @log_info.call("[StreamChecker] Optimistic playlist cache populated/updated with default streams.")
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

  def trigger_asynchronous_full_check
    @log_info.call("[StreamChecker] Triggering asynchronous full stream check and cache update...")
    Concurrent.global_io_executor.post do
      begin
        _perform_stream_checks_and_update_cache
      rescue StandardError => e
        @log_error.call("[StreamChecker] Asynchronous full check failed: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
      end
    end
  end

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
