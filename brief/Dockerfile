# Image for the Cloud Run job `sns-ads-sync` (morning brief, Google Ads reports, weekly radius sync).
# Built with the REPO ROOT as context (see brief/deploy.sh) so `brief` is importable as a package and
# brief/warehouse.py can be used when BRIEF_SOURCE=warehouse. Separate from the root Dockerfile on purpose:
# the loaders/dbt image stays free of matplotlib and the Google Ads SDK.
FROM python:3.12-slim
WORKDIR /app
COPY brief/requirements.txt ./brief/requirements.txt
RUN pip install --no-cache-dir -r brief/requirements.txt
COPY brief/*.py brief/*.json ./brief/
ENTRYPOINT ["python", "-m", "brief.sync_radii"]
CMD ["--apply"]
