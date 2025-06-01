require 'sinatra/base'
require 'httparty'
require 'nokogiri'
require 'fuzzy_match'
require 'concurrent-ruby'
require 'json' # For pretty printing hashes in logs if needed
require 'logger'
require 'fileutils'

require_relative 'stream_checker'

class IPTVProxyApp < Sinatra::Base
  # --- Configuration ---
  FUZZY_MATCH_THRESHOLD = 0.70 # For fuzzy_match (0.0 to 1.0 scale)
  M3U_INPUT_FOLDER = 'input/'
  EPG_INPUT_FILE = File.join(M3U_INPUT_FOLDER, 'guide.xml')
  LOG_FOLDER = 'logs/'
  LOG_FILE = File.join(LOG_FOLDER, 'iptv_proxy.log')
  AUTO_RELOAD_INTERVAL = 172_800 # seconds (48 hours)
  BACKGROUND_MONITOR_INTERVAL = 60 # seconds

  # --- Logging Setup ---
  FileUtils.mkdir_p(LOG_FOLDER)
  $logger = Logger.new(LOG_FILE, 3, 1_000_000) # Rotate 3 files, 1MB each
  $logger.level = Logger::INFO
  # Also log to STDOUT for Docker logs
  $stdout_logger = Logger.new(STDOUT)
  $stdout_logger.level = Logger::INFO

  def self.log_info(message)
    $logger.info(message)
    $stdout_logger.info(message)
  end

  def self.log_error(message, e = nil)
    full_message = e ? "#{message}: #{e.message}\n#{e.backtrace.join("\n")}" : message
    $logger.error(full_message)
    $stdout_logger.error(full_message)
  end
  
  def self.log_warn(message)
    $logger.warn(message)
    $stdout_logger.warn(message)
  end

  def self.log_debug(message)
    $logger.debug(message)
    # $stdout_logger.debug(message) # Optionally enable for console debug
  end


  # --- Helper Methods ---
  def self.normalize_name(name)
    return "" if name.nil? || name.empty?
    n = name.to_s.upcase # Ensure name is a string before upcasing
    n.gsub!(/\s*\(.*?\)|\[.*?\]/, '') # Remove content within parentheses or brackets
    n.gsub!(/\b(HD|FHD|UHD|4K|SD|UK|US|CA|AU|DE|PT|FR)\d*\b/i, '') # Case-insensitive removal of tags
    n.gsub!(/^(UK:|US:|CA:|PT:|ES:|TR:|LB:)/i, '') # Case-insensitive removal of prefixes
    n.gsub!(/[^\p{Alnum}\s]/u, '') # Remove punctuation, keep unicode alphanumeric. \p{Alnum} is language-agnostic.
    # Ensure n remains a string after gsub! before calling strip!
    n = n.gsub(/\s+/, ' ') # Use non-bang gsub which always returns a string
    n.strip! # Now strip! is safe as n is guaranteed to be a string

    # Iteratively remove trailing numbers if they appear to be stream indices
    previous_name_state = nil
    while n != previous_name_state
      previous_name_state = n
      n.gsub!(/^(.*\s\d+)\s\d+$/, '\1')
    end
    n
  end

  def self.load_epg_map(epg_path = EPG_INPUT_FILE)
    epg_map = {}
    return epg_map unless File.exist?(epg_path)
    begin
      doc = Nokogiri::XML(File.open(epg_path))
      doc.xpath("//channel").each do |channel_node|
        tvg_id = channel_node['id']
        next if tvg_id.nil? || tvg_id.empty?
        channel_node.xpath("display-name").each do |name_node|
          if name_node.content && !name_node.content.strip.empty?
            original_epg_name = name_node.content.strip
            normalized_epg_name = self.normalize_name(original_epg_name)
            if !epg_map.key?(normalized_epg_name)
              epg_map[normalized_epg_name] = tvg_id
            else
              self.log_warn(
                "EPG name collision: '#{original_epg_name}' and other(s) normalize to " \
                "'#{normalized_epg_name}' (tvg-id: #{tvg_id}). " \
                "Keeping tvg-id '#{epg_map[normalized_epg_name]}' from first encountered EPG entry."
              )
            end
          end
        end
      end
      self.log_info("Loaded #{epg_map.length} EPG mappings (using normalized display names).")
    rescue StandardError => e
      self.log_error("EPG parsing error", e)
    end
    epg_map
  end

  def self.parse_m3u_files(m3u_folder = M3U_INPUT_FOLDER)
    channel_entries = []
    epg_map = self.load_epg_map
    normalized_epg_names_for_fuzz = epg_map.keys

    # Prepare fuzzy matcher if there are EPG names to match against
    fuzzy_matcher = FuzzyMatch.new(normalized_epg_names_for_fuzz) if normalized_epg_names_for_fuzz && !normalized_epg_names_for_fuzz.empty?


    Dir.glob(File.join(m3u_folder, "*.m3u")).each do |m3u_file|
      self.log_info("Parsing M3U file: #{m3u_file}")
      current_attrs = {}
      File.foreach(m3u_file, encoding: "utf-8") do |line|
        line.strip!
        if line.start_with?("#EXTINF:")
          current_attrs = {}
          match_data = line.match(/#EXTINF:-1\s+(.*?)\s*,\s*(.*)/)
          if match_data
            attr_str, display_name_from_m3u = match_data.captures
            
            attr_str.scan(/(\w+?)="(.*?)"/) do |key, value|
              current_attrs[key] = value
            end
            current_attrs['display_name'] = display_name_from_m3u.strip # Original M3U display name
          
            name_to_normalize = current_attrs['display_name']
                     
            current_channel_normalized_name = self.normalize_name(name_to_normalize)
            current_attrs['canonical_name'] = current_channel_normalized_name

            # EPG ID lookup
            tvg_id_from_epg = epg_map[current_channel_normalized_name]

            if tvg_id_from_epg.nil? && fuzzy_matcher
              # Fuzzy match
              # find_best_with_score returns [match_string, score] or nil
              best_match_result = fuzzy_matcher.find_with_score(current_channel_normalized_name)
              if best_match_result
                best_match_norm_name, score = best_match_result
                if score >= FUZZY_MATCH_THRESHOLD
                    tvg_id_from_epg = epg_map[best_match_norm_name]
                    self.log_info(
                        "Fuzzy EPG match for M3U: '#{current_attrs['display_name']}' (norm: '#{current_channel_normalized_name}') -> " \
                        "EPG norm: '#{best_match_norm_name}' (tvg-id: #{tvg_id_from_epg}, score: #{score.round(2)})"
                    )
                end
              end
            end

            if tvg_id_from_epg
              current_attrs['tvg-id'] = tvg_id_from_epg
            elsif current_attrs['tvg-id'].nil? || current_attrs['tvg-id'].empty?
              self.log_warn(
                "No tvg-id found for M3U channel: '#{current_attrs['display_name']}' " \
                "(norm: '#{current_channel_normalized_name}') after EPG lookup."
              )
            end
          end
        elsif !line.start_with?("#") && !line.empty? && !current_attrs.empty?
          current_attrs['url'] = line
          channel_entries << current_attrs.dup # Use dup to avoid modification issues
          current_attrs = {} # Reset for next #EXTINF
        end
      end
    end
    self.log_info("Parsed #{channel_entries.length} channel entries from M3U files.")
    channel_entries
  end

  def self.group_channels(channel_entries)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    channel_entries.each do |entry|
      # Use canonical_name which has already been normalized
      canonical_name = entry['canonical_name']
      if canonical_name.nil? || canonical_name.empty?
        # Fallback, should ideally not happen if parse_m3u_files sets canonical_name
        self.log_warn("Entry missing canonical_name, falling back to display_name: #{entry['display_name']}")
        canonical_name = self.normalize_name(entry['display_name'] || "")
      end
      grouped[canonical_name] << entry
    end
    grouped
  end

  # --- Sinatra App Initialization & Global State ---
  set :bind, '0.0.0.0'
  set :port, 8000
  set :server, :puma

  # Global checker instance
  # Initialize with empty data; will be populated by initial load or auto-reloader
  $checker = StreamChecker.new({ "channels" => {} }, method(:log_info), method(:log_warn), method(:log_debug), method(:log_error))

  # --- Initial Data Load ---
  def self.perform_initial_load
    log_info("Performing initial M3U and EPG load...")
    # No longer need to create an instance here, call class methods directly

    entries = self.parse_m3u_files # Call class method
    grouped_channels = self.group_channels(entries) # Call class method


    log_info("Loaded channels:")
    grouped_channels.each do |name, urls|
      log_info("- #{name}: #{urls.length} stream(s)")
    end
    $checker.update_config({ "channels" => grouped_channels })
    log_info("Initial load complete. Checker updated.")
  end

  # --- Background Threads ---
  def self.start_background_tasks
    # Auto-reload M3U
    Thread.new do
      loop do
        sleep AUTO_RELOAD_INTERVAL
        log_info("Attempting to reload M3U playlist and EPG data...")
        begin
          # Call class methods directly
          new_entries = self.parse_m3u_files
          new_grouped_channels = self.group_channels(new_entries)
          $checker.update_config({ "channels" => new_grouped_channels })
          log_info("M3U playlist and EPG data reloaded, checker updated.")
        rescue StandardError => e
          log_error("Error during auto-reload", e)
        end
      end
    end
    log_info("Auto M3U reloader thread started.")

    # StreamChecker background monitor
    Thread.new do
      begin
        $checker.background_monitor(BACKGROUND_MONITOR_INTERVAL)
      rescue StandardError => e
        log_error("StreamChecker background_monitor crashed", e)
      end
    end
    log_info("StreamChecker background monitor thread started.")
  end


  # --- Routes ---
  get '/playlist.m3u' do
    content_type 'application/x-mpegURL'
    m3u_lines = ["#EXTM3U"]
    active_streams = $checker.get_active_streams # {group_name => entry_dict}

    # Sort by group_name (canonical_name) for consistent channel numbering
    sorted_channel_groups = active_streams.sort_by { |group_name, _| group_name }

    channel_number = 1
    sorted_channel_groups.each do |group_name, entry|
      next if entry.nil?

      current_tvg_id = entry["tvg-id"] || ""

      name_for_display_output = entry['canonical_name'] || group_name
      if name_for_display_output.nil? || name_for_display_output.empty?
        name_for_display_output = entry['display_name'] || ""
      end
      if name_for_display_output.nil? || name_for_display_output.empty?
        name_for_display_output = current_tvg_id
      end
      if name_for_display_output.nil? || name_for_display_output.empty?
        name_for_display_output = "Unnamed Channel #{channel_number}"
      end

      final_tvg_name_attribute = entry["tvg-name"]
      if final_tvg_name_attribute.nil? || final_tvg_name_attribute.empty?
        final_tvg_name_attribute = name_for_display_output
      end

      current_tvg_logo = entry["tvg-logo"] || ""
      current_group_title = entry["group-title"] || ""

      extinf_parts = ["#EXTINF:-1 tvg-chno=\"#{channel_number}\""]
      extinf_parts << "tvg-id=\"#{current_tvg_id}\"" unless current_tvg_id.empty?
      extinf_parts << "tvg-name=\"#{final_tvg_name_attribute}\"" # Always include
      extinf_parts << "tvg-logo=\"#{current_tvg_logo}\"" unless current_tvg_logo.empty?
      extinf_parts << "group-title=\"#{current_group_title}\"" unless current_group_title.empty?
      
      m3u_lines << "#{extinf_parts.join(' ')},#{name_for_display_output}"
      m3u_lines << entry['url']
      channel_number += 1
    end
    m3u_lines.join("\n") + "\n"
  end

  get '/failover/:channel' do
    channel_name = params['channel']
    $checker.mark_stream_failed(channel_name)
    self.class.log_info("Failover triggered for channel: #{channel_name}") # Use self.class or IPTVProxyApp
    "Failover triggered for channel: #{channel_name}\n"
  end

  get '/epg.xml' do
    content_type 'application/xml'
    return "# Error: EPG file not found at #{EPG_INPUT_FILE}" unless File.exist?(EPG_INPUT_FILE)

    begin
      doc = Nokogiri::XML(File.open(EPG_INPUT_FILE))
      
      tvg_id_to_canonical_name_map = {}
      if $checker.config && $checker.config["channels"]
        $checker.config["channels"].each_value do |entries_list|
          entries_list.each do |entry|
            if entry['tvg-id'] && entry['canonical_name']
              tvg_id_to_canonical_name_map[entry['tvg-id']] = entry['canonical_name']
            end
          end
        end
      end

      doc.xpath("//channel").each do |channel_node|
        tvg_id = channel_node['id']
        if tvg_id && tvg_id_to_canonical_name_map.key?(tvg_id)
          channel_node.xpath("display-name").each do |display_name_node|
            display_name_node.content = tvg_id_to_canonical_name_map[tvg_id]
          end
        end
      end
      doc.to_xml
    rescue StandardError => e
      self.class.log_error("EPG modification error", e) # Use self.class or IPTVProxyApp
      status 500
      "# Error processing EPG"
    end
  end

  # Perform initial load and start background tasks when the class is loaded
  # This ensures it runs once when the application starts.
  perform_initial_load
  start_background_tasks

  # For running with `ruby app.rb` directly (though `puma -C config.ru` is preferred)
  # run! if app_file == $0
end
