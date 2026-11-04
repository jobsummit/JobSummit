from functools import lru_cache
from pathlib import Path

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # --- Database -----------------------------------------------------------
    database_url: str = "postgresql+asyncpg://tracker:tracker@localhost:5432/tracker"
    db_pool_size: int = 5
    db_max_overflow: int = 5

    # --- Security -----------------------------------------------------------
    # Fernet key for the encrypted columns the saved database still has.
    vault_key: SecretStr = Field(..., description="Fernet key for encrypting portal passwords")

    # --- Gemini -------------------------------------------------------------
    gemini_api_key: SecretStr
    # Google's alias for the current Flash model: fixed names get retired
    # ("gemini-2.5-flash is no longer available to new users", Oct 2026).
    gemini_model: str = "gemini-flash-latest"
    # Tried in order when the main model is out of daily quota (quotas are per model;
    # the free tier allows about 20 requests a day for each of these).
    gemini_fallback_models: str = "gemini-3.6-flash,gemini-3.5-flash-lite,gemini-3.1-flash-lite"
    gemini_timeout_s: int = 180
    gemini_max_attempts: int = 5
    # Several notifications share one request while they fit these limits.
    gemini_batch_docs: int = 3
    gemini_batch_pages: int = 48
    # Backup reader once every Gemini model is out of free quota (Mistral's free tier).
    mistral_api_key: SecretStr = SecretStr("")
    mistral_models: str = "ministral-14b-latest,ministral-8b-latest,mistral-small-latest"
    mistral_timeout_s: int = 120
    # The practice question bank: the first model writes, a different one answers
    # each question blind (only agreed ones are kept). Big models first: facts matter
    # here; Ministral when the account can't use them.
    practice_models: str = (
        "mistral-large-latest,mistral-medium-latest,mistral-small-latest,"
        "ministral-14b-latest,ministral-8b-latest"
    )
    # The job-picks model (app/services/picks.py): a small model labels career tracks,
    # and the shared choices people opted in to come from Supabase (secret key only).
    picks_models: str = "ministral-8b-latest,ministral-14b-latest,mistral-small-latest"
    supabase_url: str = "https://mowurjbmifkwlaogidns.supabase.co"
    supabase_secret_key: SecretStr = SecretStr("")

    # --- Uploads ------------------------------------------------------------
    upload_dir: Path = Path("/data/notifications")
    max_upload_mb: int = 40
    # PDFs longer than this are trimmed to their relevant pages before Gemini sees them.
    pdf_slice_min_pages: int = 12
    pdf_slice_max_pages: int = 24

    # --- Domain -------------------------------------------------------------
    timezone: str = "Asia/Kolkata"

    # --- Crawling ---------------------------------------------------------------
    # Honest product token, no browser impersonation. Keep it free of "bot", URLs and
    # e-mail addresses: upsc.gov.in's firewall returns 403 for any of those (tested Oct 2026).
    scraper_user_agent: str = "ExamTracker/0.3 (personal exam tracker)"
    extra_ca_bundle: str | None = None  # optional extra PEM appended to the bundled intermediates
    # Needed for old state-commission servers (e.g. upsssc.gov.in); certs are still verified.
    tls_allow_legacy_renegotiation: bool = True
    crawl_interval_hours: float = 4.0
    crawl_jitter_minutes: int = 30  # ± spread so sources never fire in lockstep
    per_host_min_interval_s: float = 8.0  # politeness gap between hits on one host
    crawl_concurrency: int = 3  # different hosts in parallel
    fetch_timeout_s: float = 25.0
    max_page_mb: int = 8
    respect_robots_txt: bool = True
    playwright_enabled: bool = False  # needs the image built with WITH_CHROMIUM=1
    aggregator_detail_pages_per_run: int = 15  # SarkariResult/FJA follow-ups per crawl
    ingest_batch_size: int = 6  # PDFs per ingest round (read gemini_batch_docs per request)

    @property
    def max_upload_bytes(self) -> int:
        """Largest notification PDF the pipeline downloads."""
        return self.max_upload_mb * 1024 * 1024

    @property
    def max_page_bytes(self) -> int:
        return self.max_page_mb * 1024 * 1024


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
