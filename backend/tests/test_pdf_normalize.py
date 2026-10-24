from zoneinfo import ZoneInfo

from app.schemas.extraction import NotificationExtraction
from app.services.pdf_parser import normalize_extraction

IST = ZoneInfo("Asia/Kolkata")


def _raw(**over) -> NotificationExtraction:
    vac = {"ur": 10, "sc": 3, "st": 1, "obc": 5, "ews": 2, "total": 21, "pwbd": None, "ex_serviceman": None}
    base = {
        "organization": "Bharat Electronics Limited",
        "exam_name": "Probationary Engineer 2026",
        "advertisement_no": "BEL/PE/2026/01",
        "official_portal_url": "www.bel-india.in",
        "application_start_date": "2026-10-01",
        "application_end_date": "15.11.2026",
        "application_end_time": "17:00",
        "exam_date": None,
        "age_as_on_date": "2026-10-01",
        "fee_payment_last_date": None,
        "correction_window_start_date": None,
        "correction_window_end_date": None,
        "admit_card_release_date": None,
        "exam_end_date": None,
        "answer_key_date": None,
        "result_date": None,
        "employment_type": None,
        "application_fees": [],
        "fee_refund": None,
        "general_age_relaxations": [
            {"category": "OBC (NCL)", "years": 3},
            {"category": "SC/ST", "years": 5},
            {"category": "PwBD", "years": 10},
        ],
        "posts": [
            {
                "post_code": "PE-ECE",
                "post_name": "Probationary Engineer (E&C)",
                "min_age": None,
                "max_age_ur": 25,
                "age_as_on_date": None,
                "eligible_degrees": [
                    "B.E./B.Tech Electronics & Communication",
                    " b.e./b.tech electronics & communication ",
                ],
                "qualification_summary": None,
                "eligibility_text": None,
                "min_qualification_level": None,
                "open_to_any_graduate": None,
                "open_to_any_post_graduate": None,
                "min_experience_years": None,
                "pay_scale": None,
                "monthly_pay_min": None,
                "vacancies": vac,
                "age_relaxations": [],
            }
        ],
    }
    base.update(over)
    return NotificationExtraction.model_validate(base)


def test_happy_path():
    n = normalize_extraction(_raw(), tz=IST)
    assert n.application_deadline.isoformat() == "2026-11-15T17:00:00+05:30"
    assert n.portal_url == "https://www.bel-india.in"
    post = n.posts[0]
    assert post.age_relaxation_overrides == {"OBC": 3, "SC": 5, "ST": 5, "PWBD": 10}
    assert post.eligible_streams == ["B.E./B.Tech Electronics & Communication"]
    assert post.vacancy.total == 21
    assert not n.needs_review, n.review_notes


def test_fees_are_kept_per_category_and_misreads_dropped():
    n = normalize_extraction(
        _raw(
            application_fees=[
                {"category": "General", "amount": 500},
                {"category": "SC", "amount": 250},
                {"category": "Female", "amount": 250},
                {"category": "OBC", "amount": 50000},  # a misread
                {"category": "Domicile", "amount": 100},  # not a category
            ],
            fee_refund="Rs 400 refunded on appearing in CBT-1",
        ),
        tz=IST,
    )
    assert n.fees == {"UR": 500, "SC": 250, "WOMEN": 250}
    assert n.fee_refund == "Rs 400 refunded on appearing in CBT-1"


def test_seat_mismatch_flags_review():
    raw = _raw()
    raw.posts[0].vacancies.total = 30
    n = normalize_extraction(raw, tz=IST)
    assert n.needs_review
    assert any("printed total" in note for note in n.review_notes)


def test_missing_age_cutoff_falls_back_to_closing_date():
    n = normalize_extraction(_raw(age_as_on_date=None), tz=IST)
    assert n.posts[0].age_as_on.isoformat() == "2026-11-15"
    assert n.needs_review


def test_qualification_rules_inferred_from_degree_lines_when_not_extracted():
    post = normalize_extraction(_raw(), tz=IST).posts[0]
    assert post.min_qualification_level == "UG"
    assert post.allowed_degrees == ["B_TECH"]
    assert not post.is_open_to_any_graduate and not post.is_open_to_any_post_graduate
    assert post.min_experience_years == 0


def test_explicit_qualification_fields_win_and_flags_merge():
    raw = _raw()
    raw.posts[0].min_qualification_level = "Post Graduate"
    raw.posts[0].open_to_any_graduate = None
    raw.posts[0].eligible_degrees = ["Any Graduate"]
    raw.posts[0].min_experience_years = 2.5
    post = normalize_extraction(raw, tz=IST).posts[0]
    assert post.min_qualification_level == "PG"
    assert post.is_open_to_any_graduate  # inferred from the "Any Graduate" line
    assert post.min_experience_years == 2.5


def test_unknown_level_is_noted_not_fatal():
    raw = _raw()
    raw.posts[0].min_qualification_level = "Doctor of Magic"
    n = normalize_extraction(raw, tz=IST)
    assert n.posts[0].min_qualification_level == "UG"  # falls back to the degree lines
    assert any("unknown qualification level" in note for note in n.review_notes)


def test_schedule_dates_become_the_timeline():
    n = normalize_extraction(
        _raw(exam_date="2026-12-14", admit_card_release_date="05.12.2026", result_date="2027-02-01"),
        tz=IST,
    )
    assert n.timeline.exam_start.isoformat() == "2026-12-14"
    assert n.timeline.admit_card_release.isoformat() == "2026-12-05"
    assert n.timeline.result_date.isoformat() == "2027-02-01"
    assert n.timeline.answer_key_release is None


def test_pay_and_job_type_are_kept_and_sanity_checked():
    raw = _raw(employment_type="Contractual")
    raw.posts[0].pay_scale = "Level 6 (Rs 35,400 - 1,12,400)"
    raw.posts[0].monthly_pay_min = 35400
    n = normalize_extraction(raw, tz=IST)
    assert n.employment_type == "contract"
    assert (n.posts[0].pay_scale, n.posts[0].monthly_pay_min) == ("Level 6 (Rs 35,400 - 1,12,400)", 35400)

    raw.posts[0].monthly_pay_min = 35  # "35 thousand" misread
    n = normalize_extraction(raw, tz=IST)
    assert n.posts[0].monthly_pay_min is None
    assert any("implausible monthly pay" in note for note in n.review_notes)
