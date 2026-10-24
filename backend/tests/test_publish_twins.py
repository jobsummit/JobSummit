import uuid
from datetime import UTC, datetime

from app.models import JobPost, PostDetail
from app.services.publish import advert_key, same_board, without_twins


def _job(org: str, adv: str | None, posts: list[str], *, pdf: bool = True, **kw) -> JobPost:
    job = JobPost(
        id=uuid.uuid4(),
        organization=org,
        exam_name=kw.pop("exam_name", "Recruitment 2026"),
        advertisement_no=adv,
        application_deadline=kw.pop("due", datetime(2026, 11, 6, 18, 29, tzinfo=UTC)),
        needs_review=False,
        source_pdf_path=f"/tmp/x.{'pdf' if pdf else 'txt'}",
        **kw,
    )
    job.timeline = None
    job.posts = [
        PostDetail(
            id=uuid.uuid4(),
            post_name=name,
            eligible_streams=[],
            allowed_degrees=[],
            is_open_to_any_graduate=True,
            is_open_to_any_post_graduate=False,
            min_experience_years=0.0,
            age_relaxation_overrides={},
        )
        for name in posts
    ]
    return job


NTPC_POSTS = ["Goods Train Manager", "Senior Clerk cum Typist", "Junior Accounts Assistant cum Typist"]


def test_advert_numbers_written_differently():
    assert (
        advert_key("CEN No. 06/2026") == advert_key("CEN 06/2026") == advert_key("CEN 6/2026") == "cen-6-2026"
    )
    assert advert_key("Ref: GHB/ADM/1708 /2026") == advert_key("GHB/ADM/1708/2026")
    assert advert_key("No.") is None
    assert advert_key(None) is None


def test_one_board_named_two_ways():
    assert same_board("Railway Recruitment Boards", "Railway Recruitment Board (RRB)")
    assert same_board("Haryana Public Service Commission", "Haryana Public Service Commission (HPSC)")
    assert same_board("SSC", "Staff Selection Commission")
    assert not same_board(
        "District Collector Hyderabad", "Office of the District Collector and Magistrate, Wanaparthy District"
    )
    assert not same_board("Tehsildar Office Rajapur", "Collector Office Nashik")


def test_two_copies_of_rrb_ntpc_become_one():
    from_pdf = _job(
        "Railway Recruitment Board (RRB)", "CEN 06/2026", NTPC_POSTS, portal_url="https://rrb.gov.in"
    )
    from_page = _job(
        "Railway Recruitment Boards",
        "CEN No. 06/2026",
        [*NTPC_POSTS, "Chief Commercial cum Ticket Supervisor"],
        pdf=False,
        apply_url="https://www.rrbapply.gov.in/",
    )
    rows = without_twins([from_page, from_pdf])
    assert len(rows) == 1
    kept = rows[0]
    assert kept["id"] == str(from_pdf.id)  # read from the notification itself
    assert kept["apply_url"] == "https://www.rrbapply.gov.in/"  # filled in from the other copy
    assert kept["same_as"] == [str(from_page.id)]


def test_separate_notices_stay_apart():
    a = _job("District Collector Hyderabad", "2000/Estt/RDDH/HYD/2026", ["AYUSH Medical Officer"])
    b = _job(
        "Office of the District Collector and Magistrate, Wanaparthy District",
        "No.2000/Estt/RDDH/HYD/2026",
        ["AYUSH Medical Officer"],
    )
    c = _job("Railway Recruitment Boards", "CEN 06/2026", NTPC_POSTS, due=datetime(2026, 12, 1, tzinfo=UTC))
    d = _job("Railway Recruitment Boards", "CEN 06/2026", ["Assistant Loco Pilot"])
    e = _job("Railway Recruitment Boards", "CEN 06/2026", NTPC_POSTS)
    # Two districts sharing an order number; another closing day; other posts.
    rows = without_twins([a, b, c, d, e])
    assert len(rows) == 5
    assert all("same_as" not in r for r in rows)
