# =============================================================================
# Shellder Service Container
# =============================================================================
# Provides:
#   - Shellder GUI (Web Dashboard) on port 5000
#   - Live container stats monitoring
#   - Xilriws proxy stats collection
#   - Log aggregation and analysis
#   - WebSocket for real-time updates
# =============================================================================

FROM python:3.12-slim

LABEL maintainer="The Pokemod Group"
LABEL description="Shellder - Control Panel & Monitoring Service for Aegis AIO"
LABEL version="1.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements first for caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
# Note: gui_server.py is deprecated, shellder_service.py is the unified server
COPY shellder_service.py .
COPY debug_logger.py .
COPY gui_templates/ ./gui_templates/
COPY gui_static/ ./gui_static/

# Copy helper scripts for reference (read-only access)
COPY db_helper.sh ./db_helper.sh
COPY log_helper.sh ./log_helper.sh

# Create directories for data persistence with open permissions
# These will be mounted from host anyway, but having them pre-created helps
RUN mkdir -p /app/data /app/logs && \
    chmod 777 /app/data /app/logs

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV FLASK_ENV=production
ENV SHELLDER_PORT=5000
ENV AEGIS_ROOT=/aegis

# Expose port
EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/api/health || exit 1

# Run the service
# Note: When running with user: directive in docker-compose.yaml,
# the process runs as that user, preventing root-locked files
CMD ["python", "shellder_service.py"]

