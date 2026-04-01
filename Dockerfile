FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ ./app/

# Copy config files (schedule, strategy) into the image
COPY quarterly_schedule.csv /config/quarterly_schedule.csv
COPY content_strategy.md /config/content_strategy.md
COPY engagement_tracker.csv /config/engagement_tracker.csv

# Create content directories
RUN mkdir -p /holm-content/inbox /holm-content/scheduled /holm-content/posted /holm-content/rejected /data

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "-m", "app.bot"]
