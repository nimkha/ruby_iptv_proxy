# IPTV Proxy (Ruby Version)

This project is a Ruby-based IPTV proxy with channel grouping, failover, and EPG support.

## Features

- Parses M3U playlists and XMLTV EPG files.
- Normalizes and groups channels with similar names.
- Provides a `/playlist.m3u` URL with consistently numbered channels.
- Actively checks stream health and serves only working streams.
- Automatic failover to the next stream in a group if the current one fails.
- Background monitoring of streams.
- Automatic reloading of M3U and EPG data.
- Modifies EPG display names to match normalized/aliased channel names.

## Prerequisites

- Ruby (e.g., version 3.1 or later)
- Bundler (`gem install bundler`)

## Setup

1.  **Clone the repository (or extract the files to a directory named `ruby_iptv_proxy`).**
2.  **Navigate to the project directory:**
    ```bash
    cd ruby_iptv_proxy
    ```
3.  **Install dependencies:**
    ```bash
    bundle install
    ```
4.  **Prepare Input Files:**
    - Create an `input` directory if it doesn't exist.
    - Place your M3U playlist files (e.g., `provider1.m3u`) inside the `input` directory.
    - Place your EPG XML file, named `guide.xml`, inside the `input` directory.

## Running the Application

### Directly with Puma (Recommended for development/production)

```bash
bundle exec puma -p 8000 config.ru
