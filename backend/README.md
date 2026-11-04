# JobSummit data pipeline

Python that runs on GitHub Actions (no server). It finds recruitment notifications, reads their
PDFs with AI, and publishes JSON files to the repository's `data` branch, which GitHub Pages
serves to the app.

| Workflow | When | What it publishes |
|---|---|---|
| `.github/workflows/data-pipeline.yml` | every 2 hours | `jobs.json`, `notices.json`, `status.json`, `practice/*.json`, `picks.json`, `private_jobs.json`, `state/` (the database dump the next run starts from) |
| `.github/workflows/notices.yml` | every 30 minutes | `notices.json` only (admit cards, answer keys, results) |

## What runs

- `scripts/run_pipeline.py`: crawl the sources in `app/services/seeds.py`
  (`scraper_service.py`, `discovery_pipeline.py`), read new PDFs with Gemini
  (`pdf_parser.py`, Mistral as backup in `mistral_reader.py`), store them (`ingestion.py`), label
  notices (`notice_labels.py`) and write the files (`publish.py`).
- `app/services/practice_bank.py` and `current_affairs.py`: the practice question bank.
- `app/services/picks.py`: the job-picks model (career tracks, and weights from the choices phones
  share through Supabase: `supabase/insights.sql`).
- `app/modules/private_jobs`: the optional Private jobs feed (company job boards).

A throwaway PostgreSQL holds the state during a run; `state/db.sql.gz` carries it to the next one.

## Secrets (repository settings)

`GEMINI_API_KEY` (PDFs), `MISTRAL_API_KEY` (labels, questions, backup reading),
`SUPABASE_SECRET_KEY` (reading the shared choices). Each is optional: without it, that part waits.

## Develop

```bash
python -m venv .venv && .venv/Scripts/python -m pip install -r requirements-dev.txt
.venv/Scripts/python -m pytest
.venv/Scripts/python -m ruff check app tests scripts && .venv/Scripts/python -m ruff format app tests scripts
```

Run the pipeline locally against a PostgreSQL of your own:
`python scripts/run_pipeline.py --out ../publish` (with `DATABASE_URL`, `VAULT_KEY` and the keys
above in `.env`; see `.env.example`).

After editing `app/domain/qualifications.py`, run `python scripts/export_taxonomy.py`: the app keeps
a copy, and a test checks they match.
