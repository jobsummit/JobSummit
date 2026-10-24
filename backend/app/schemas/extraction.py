"""LLM-facing schema passed to Gemini as ``response_schema``.

Kept intentionally "dumb" for maximum compatibility with Gemini's OpenAPI-subset
schema support: no defaults, no dicts, dates as ISO strings. Every field is
required-but-nullable so the model must make an explicit decision.
Strong typing and sanity checks happen afterwards in ``schemas/notification.py``.
"""

from pydantic import BaseModel, Field


class ExtractedRelaxation(BaseModel):
    category: str = Field(description="One of: SC, ST, OBC, EWS, PWBD, EXSM")
    years: int = Field(description="Upper age relaxation in years for this category")


class ExtractedFee(BaseModel):
    category: str = Field(description="One of: UR, OBC, EWS, SC, ST, PWBD, WOMEN, EXSM, ALL")
    amount: int = Field(description="Application fee in rupees for this category (0 if exempt)")


class ExtractedVacancy(BaseModel):
    ur: int | None = Field(description="Unreserved / General / UR / GEN seats")
    sc: int | None = Field(description="Scheduled Caste seats")
    st: int | None = Field(description="Scheduled Tribe seats")
    obc: int | None = Field(description="OBC / OBC-NCL seats")
    ews: int | None = Field(description="Economically Weaker Section seats")
    total: int | None = Field(description="Total seats for the post as printed")
    pwbd: int | None = Field(description="PwBD / PH / Divyang seats (horizontal), if printed")
    ex_serviceman: int | None = Field(description="Ex-Servicemen seats (horizontal), if printed")


class ExtractedPost(BaseModel):
    post_code: str | None = Field(description="Post code / advt. post no., verbatim")
    post_name: str = Field(description="Post / discipline name in English")
    min_age: int | None = Field(description="Minimum age in years")
    max_age_ur: int | None = Field(description="Maximum age in years for UR/General")
    age_as_on_date: str | None = Field(
        description="Post-specific age cut-off date (YYYY-MM-DD); "
        "only if it differs from the notification-wide one"
    )
    eligible_degrees: list[str] = Field(
        description="One short entry per degree+branch, e.g. 'B.E./B.Tech Electronics & Communication'. "
        "Use 'Any Graduate' or 'B.E./B.Tech Any Branch' for open eligibility."
    )
    qualification_summary: str | None = Field(description="One-sentence plain-English qualification summary")
    eligibility_text: str | None = Field(
        description="The post's essential-qualification paragraph copied verbatim (English), max ~800 chars"
    )
    min_qualification_level: str | None = Field(
        description="Lowest qualification that makes a candidate eligible. One of: "
        "MATRIC (10th), INTERMEDIATE (12th), DIPLOMA, UG (bachelor's), PG (master's), PHD"
    )
    open_to_any_graduate: bool | None = Field(
        description="true if a bachelor's degree in ANY discipline is enough ('Any Graduate')"
    )
    open_to_any_post_graduate: bool | None = Field(
        description="true if a master's degree in ANY discipline is enough ('Any Post Graduate')"
    )
    min_experience_years: float | None = Field(
        description="Minimum post-qualification work experience in years; 0 or null if none required"
    )
    pay_scale: str | None = Field(
        description="Pay as printed: pay level / pay scale / fixed monthly pay or stipend, e.g. "
        "'Level 6 (Rs 35,400-1,12,400)' or 'Rs 37,000 per month (consolidated)'"
    )
    monthly_pay_min: int | None = Field(
        description="Lowest monthly amount in rupees: entry basic pay of the scale, or the fixed monthly "
        "pay/stipend; null if not printed. 'Level 6' alone is not a number: give its entry basic pay (35400)"
    )
    vacancies: ExtractedVacancy
    age_relaxations: list[ExtractedRelaxation] = Field(
        description="Only relaxations specific to this post that differ from the notification-wide list"
    )


class NotificationExtraction(BaseModel):
    organization: str = Field(description="Recruiting organisation, e.g. 'Bharat Electronics Limited'")
    exam_name: str = Field(description="Recruitment / exam title")
    advertisement_no: str | None
    official_portal_url: str | None = Field(description="Online application URL printed in the notification")
    application_start_date: str | None = Field(description="YYYY-MM-DD")
    application_end_date: str | None = Field(description="Last date for online application, YYYY-MM-DD")
    application_end_time: str | None = Field(description="Closing time on the last date, 24h HH:MM")
    exam_date: str | None = Field(description="Tentative exam date, YYYY-MM-DD")
    age_as_on_date: str | None = Field(description="Date on which age is reckoned, YYYY-MM-DD")
    fee_payment_last_date: str | None = Field(description="Last date for fee payment, YYYY-MM-DD")
    correction_window_start_date: str | None = Field(description="Application edit/correction window opens")
    correction_window_end_date: str | None = Field(description="Application edit/correction window closes")
    admit_card_release_date: str | None = Field(description="Tentative admit card / hall ticket date")
    exam_end_date: str | None = Field(description="Last day of a multi-day exam window, YYYY-MM-DD")
    answer_key_date: str | None = Field(description="Tentative answer key release date")
    result_date: str | None = Field(description="Tentative result declaration date")
    employment_type: str | None = Field(
        description="One of: permanent, contract, apprenticeship, fellowship, internship"
    )
    application_fees: list[ExtractedFee] = Field(
        description="Application / exam fee per category as printed (UR = General); empty if not printed"
    )
    fee_refund: str | None = Field(
        description="Fee refund rule if printed, short, e.g. 'Rs 400 refunded on appearing in CBT-1'"
    )
    general_age_relaxations: list[ExtractedRelaxation]
    posts: list[ExtractedPost]


class NumberedExtraction(BaseModel):
    document_number: int = Field(description="N from the 'Document N:' label placed just before the PDF")
    notification: NotificationExtraction


class BatchExtraction(BaseModel):
    """Several PDFs read in one request: the free tier counts requests, not PDFs."""

    documents: list[NumberedExtraction] = Field(description="Exactly one entry per attached document")
