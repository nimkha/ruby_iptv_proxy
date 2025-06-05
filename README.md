# Ruby IPTV Proxy

This application acts as a proxy for IPTV streams, allowing for channel grouping, EPG (XMLTV) manipulation, and stream failover.

## Features

*   Parses M3U playlists.
*   Groups channels by a canonical name derived from M3U attributes.
*   Integrates with an XMLTV EPG file, mapping EPG data to channels using direct and fuzzy name matching.
*   Provides a `/playlist.m3u` endpoint with failover: if a stream for a channel group is down, it attempts to serve the next available stream for that group.
*   Provides an `/epg.xml` endpoint with channel names updated to match the canonical names used in the playlist.
*   Background stream checking and M3U/EPG auto-reloading.

## Running the Application (Non-Docker)

### Prerequisites

*   Ruby (e.g., version 3.1 or later)
*   Bundler (`gem install bundler`)

### Setup

1.  **Clone the Repository:**
    ```bash
    git clone <your-repository-url> # Or extract files to a directory
    cd ruby_iptv_proxy
    ```

2.  **Install Dependencies:**
    ```bash
    bundle install
    ```

3.  **Prepare Input Files:**
    *   Create an `input` directory in the project root: `mkdir -p input`
    *   Place your M3U playlist files (e.g., `primary.m3u`, `secondary.m3u`) inside the `input` directory.
    *   Place your XMLTV EPG file, named `guide.xml` by default (see `EPG_INPUT_FILE` in `app.rb`), inside the `input` directory.

### Running the Application

Directly with Puma (Recommended for development/production):
```bash
bundle exec puma -p 8000 config.ru
bundle exec puma -C config/puma.rb
```

## Running with Docker Compose

Using Docker Compose is the recommended way to run this application.

### Prerequisites

*   Docker installed.
*   Docker Compose installed.

### Steps

1.  **Clone the Repository:**
    ```bash
    git clone <your-repository-url>
    cd ruby_iptv_proxy
    ```

2.  **Prepare Input Files:**
    *   Create an `input` directory in the project root if it doesn't exist: `mkdir -p input`
    *   Place your M3U playlist files (e.g., `primary.m3u`, `secondary.m3u`) inside the `input` directory.
    *   Place your XMLTV EPG file (e.g., `guide.xml`) inside the `input` directory. The application expects it to be named `guide.xml` by default (see `EPG_INPUT_FILE` in `app.rb`).

3.  **Build and Run the Container:**

    ```bash
    docker compose build
    ```

    ```bash
    docker compose up -d
    ```
    This command will build the Docker image (if it's the first time or if the `Dockerfile` changed) and start the application container in detached mode.

4.  **Accessing the Application:**
    *   Playlist: `http://localhost:8000/playlist.m3u`
    *   EPG: `http://localhost:8000/epg.xml`

5.  **Viewing Logs:**
    *   To view the application logs from the container:
        ```bash
        docker compose logs -f iptv-proxy
        ```
    *   Log files are also persisted in the `logs` directory on your host machine.

6.  **Stopping the Application:**
    ```bash
    docker compose down
    ```

---