import json
import uuid
from datetime import UTC, date, datetime

from app.domain.qualifications import QualificationLevel
from app.models import JobPost, PostDetail, VacancyMatrix
from app.services.publish import job_json, merged_requirement


def _post(**kw) -> PostDetail:
    base = dict(
        id=uuid.uuid4(),
        post_name="Inspector",
        eligible_streams=[],
        allowed_degrees=[],
        min_qualification_level=None,
        is_open_to_any_graduate=False,
        is_open_to_any_post_graduate=False,
        min_experience_years=0.0,
        age_relaxation_overrides={},
    )
    base.update(kw)
    return PostDetail(**base)


def test_degree_lines_are_merged_into_the_published_rules():
    merged = merged_requirement(
        _post(
            eligible_streams=["B.E./B.Tech Civil", "Graduation in any discipline"], allowed_degrees=["B_SC"]
        )
    )
    assert merged == {
        "allowed_degrees": ["B_SC", "B_TECH"],
        "min_qualification_level": "UG",
        "is_open_to_any_graduate": True,
        "is_open_to_any_post_graduate": False,
    }


def test_explicit_lower_level_wins():
    merged = merged_requirement(
        _post(eligible_streams=["B.E. Civil"], min_qualification_level=QualificationLevel.DIPLOMA)
    )
    assert merged["min_qualification_level"] == "DIPLOMA"


def test_job_json_is_plain_json_with_timeline():
    job = JobPost(
        id=uuid.uuid4(),
        organization="SSC",
        exam_name="CGL 2026",
        application_start=datetime(2026, 9, 1, tzinfo=UTC),
        application_deadline=datetime(2026, 10, 1, 18, tzinfo=UTC),
        exam_date=date(2026, 12, 14),
        needs_review=False,
        portal_url="https://ssc.gov.in",
        apply_url="https://ssc.gov.in/login#/register",
    )
    job.timeline = None
    post = _post(eligible_streams=["Any graduate"], age_as_on=date(2026, 8, 1), base_max_age=27)
    post.vacancy = VacancyMatrix(ur=10, sc=3, st=1, obc=5, ews=2, total=21)
    job.posts = [post]

    data = json.loads(json.dumps(job_json(job)))  # must survive a JSON round trip
    assert data["application_deadline"] == "2026-10-01T18:00:00+00:00"
    assert (data["portal_url"], data["apply_url"]) == (
        "https://ssc.gov.in",
        "https://ssc.gov.in/login#/register",
    )
    assert data["timeline"]["exam_start"] == "2026-12-14"
    p = data["posts"][0]
    assert p["is_open_to_any_graduate"] and p["min_qualification_level"] == "UG"
    assert p["vacancy"] == {"ur": 10, "sc": 3, "st": 1, "obc": 5, "ews": 2, "total": 21}
    assert p["age_as_on"] == "2026-08-01"


def test_jobs_get_a_category_for_filtering():
    from app.services.publish import job_category

    assert job_category("Railway Recruitment Board", "RRB NTPC Graduate Level 2026") == "railway"
    assert job_category("Institute of Banking Personnel Selection", "CRP PO/MT-XVI") == "bank"
    assert job_category("Staff Selection Commission", "Combined Graduate Level 2026") == "ssc"
    assert job_category("IIT Kharagpur", "Junior Research Fellow [JRF]") == "research"
    assert job_category("Bharat Electronics Limited", "Probationary Engineer") == "psu"
    assert job_category("Tata Memorial Centre", "Gardener") == "other"


def test_a_job_sites_address_is_not_the_boards_site():
    job = JobPost(
        id=uuid.uuid4(),
        organization="Railway Recruitment Boards",
        exam_name="RRB NTPC Graduate Recruitment 2026",
        needs_review=True,
        portal_url="https://www.freejobalert.com/articles/rrb-ntpc-graduate-recruitment-062026-3068511",
        apply_url="https://www.rrbapply.gov.in/",
    )
    job.timeline = None
    job.posts = []
    data = job_json(job)
    assert data["portal_url"] is None
    assert data["apply_url"] == "https://www.rrbapply.gov.in/"
