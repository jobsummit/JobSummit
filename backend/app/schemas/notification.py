"""Validated, strongly-typed notification ready to persist."""

from datetime import date

from pydantic import AwareDatetime, BaseModel, Field, NonNegativeInt

from app.domain.qualifications import QualificationLevel


class ParsedVacancy(BaseModel):
    ur: NonNegativeInt = 0
    sc: NonNegativeInt = 0
    st: NonNegativeInt = 0
    obc: NonNegativeInt = 0
    ews: NonNegativeInt = 0
    total: NonNegativeInt = 0
    pwbd: NonNegativeInt | None = None
    ex_serviceman: NonNegativeInt | None = None


class ParsedPost(BaseModel):
    post_code: str | None = Field(None, max_length=60)
    post_name: str = Field(min_length=1, max_length=300)
    min_age: int | None = Field(None, ge=14, le=70)
    base_max_age: int | None = Field(None, ge=14, le=70)
    age_as_on: date | None = None
    eligible_streams: list[str] = Field(default_factory=list)
    qualification_text: str | None = None
    age_relaxation_overrides: dict[str, int] = Field(default_factory=dict)
    allowed_degrees: list[str] = Field(default_factory=list)  # degree codes
    raw_eligibility_text: str | None = None
    min_qualification_level: QualificationLevel | None = None
    is_open_to_any_graduate: bool = False
    is_open_to_any_post_graduate: bool = False
    min_experience_years: float = Field(0.0, ge=0, le=40)
    pay_scale: str | None = Field(None, max_length=300)
    monthly_pay_min: int | None = Field(None, ge=0)
    vacancy: ParsedVacancy


class ParsedTimeline(BaseModel):
    """Tentative schedule printed in the notification (later stages come from alerts)."""

    fee_deadline: date | None = None
    edit_window_start: date | None = None
    edit_window_end: date | None = None
    admit_card_release: date | None = None
    exam_start: date | None = None
    exam_end: date | None = None
    answer_key_release: date | None = None
    result_date: date | None = None


class ParsedNotification(BaseModel):
    organization: str = Field(min_length=1, max_length=200)
    exam_name: str = Field(min_length=1, max_length=300)
    advertisement_no: str | None = Field(None, max_length=120)
    portal_url: str | None = Field(None, max_length=1000)
    application_start: AwareDatetime | None = None
    application_deadline: AwareDatetime | None = None
    exam_date: date | None = None
    posts: list[ParsedPost] = Field(min_length=1)
    timeline: ParsedTimeline = Field(default_factory=ParsedTimeline)
    employment_type: str | None = None  # permanent | contract | apprenticeship | fellowship | internship
    # Fee in rupees per category ("UR", "SC", ..., "ALL" when one fee for everyone).
    fees: dict[str, int] = Field(default_factory=dict)
    fee_refund: str | None = Field(None, max_length=300)
    review_notes: list[str] = Field(default_factory=list)
    extraction_model: str | None = None  # the Gemini model that actually read it

    @property
    def needs_review(self) -> bool:
        return bool(self.review_notes)
