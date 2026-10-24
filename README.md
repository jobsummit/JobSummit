# JobSummit

**Government jobs without the chaos.** A free, calm Android app for Indian government and PSU
jobs: it shows only the jobs you can apply for, tracks every exam from form to result, and helps
you practise for it. One clear next step at a time.

**Download:** [latest release](https://github.com/jobsummit/JobSummit/releases/latest)
(most phones: the `arm64-v8a` file) · [home page](https://jobsummit.github.io/JobSummit/) ·
[privacy policy](https://jobsummit.github.io/JobSummit/privacy.html)

## What it does

**Jobs you are eligible for**
- New SSC, railway, bank, UPSC, state PSC, defence, teaching and PSU notifications, read from the
  official notices every few hours.
- Only the posts that fit your age, category, qualification, subject and experience, with age
  relaxation worked out and the seats open to your category.
- Your fee, the last date and the official link for each job. Share a job from WhatsApp or
  Telegram and the app finds it.

**Every exam, from form to result**
- Watches the boards' notice pages for admit cards, exam dates, answer keys, results and
  form-correction windows.
- One quiet morning summary of forms closing soon; nothing rings at night.
- Warns about two exams on one day, and adds dates to your calendar with reminders.
- Scores your response sheet: paste its link and see your marks per section, with the exam's
  own marking.
- Keeps your registration and roll numbers and portal passwords, and makes your photo and
  signature in each form's size.
- Shows until which year your age lets you apply for each exam, and attempts left where they
  are counted.

**Practice that feels like the exam**
- Timed tests in maths, reasoning, English, general awareness, current affairs, science,
  computer and banking.
- Full mocks in the pattern of SSC CGL, CHSL, MTS, GD, IBPS and SBI PO and Clerk, RRB NTPC,
  Group D, ALP and more.
- A Daily 10 (the same ten questions for everyone each day), every answer explained, and a
  mistake notebook that brings wrong answers back after 1, 3 and 7 days.

Made for people who find job hunting overwhelming, including people with ADHD: the most urgent
thing first, XP and streaks for steps that move you forward, no ads, no tracking, no account
needed (Google sign-in is optional, for a backup in your own Drive). To make job picks better for
everyone, the app shares without names which jobs people apply to (on by default; one switch in
Settings turns it off and another deletes what was shared).

## How it works

There is no app server. A data pipeline runs on GitHub Actions every two hours: it finds new
notifications, reads their PDFs with AI, and publishes `jobs.json`, `notices.json` and the
practice question bank to the `data` branch (served by GitHub Pages). The app downloads those
files and does everything else on the phone: eligibility, the exam watcher, reminders, tests.

**Job picks.** Unless they turn it off, phones share their profile in bands (age range, category,
qualification level, degrees), preferences, tracked exams and which jobs they applied to or turned
down, keyed by a random id, never by name (`backend/supabase/insights.sql`). The pipeline's
picks step has a small model (Ministral 8B) label each job's career track, and learns per-degree
weights from the shared choices, publishing only groups of 5 or more people in `picks.json`. The
phone adds those to its own learned likes at half weight.

Maths and reasoning questions are made on the phone, so their answers are right by
construction. English, general awareness, science, computer and banking questions are written by
one AI model and kept only when a second model, answering blind, agrees. Current affairs come
from the text of official PIB press releases, each linked to its source.

| Folder | What |
|---|---|
| [`mobile/`](mobile/README.md) | The Flutter Android app |
| [`backend/`](backend/README.md) | The data pipeline (Python), run by `.github/workflows/data-pipeline.yml` and `notices.yml` |
| [`site/`](site/) | The home page and privacy policy (GitHub Pages) |
| [`branding/`](branding/) | App icon and store images |

**Test on your phone:** [`TESTING.md`](TESTING.md) · **Release the app:** [`mobile/RELEASING.md`](mobile/RELEASING.md)
