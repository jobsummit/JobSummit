import pytest

from app.domain.enums import ExamMilestone
from app.services.milestones import classify_milestone


@pytest.mark.parametrize(
    ("text", "milestone"),
    [
        ("SSC CGL Tier-I Admit Card / Hall Ticket Download", ExamMilestone.ADMIT_CARD),
        ("Call Letter for Document Verification", ExamMilestone.ADMIT_CARD),
        ("Exam Date announced for CEN 03/2026", ExamMilestone.EXAM_SCHEDULE),
        ("Exam City Intimation Slip", ExamMilestone.EXAM_SCHEDULE),
        ("Tier-II exam postponed", ExamMilestone.POSTPONED),
        ("Rescheduled Admit Card for Shift 2", ExamMilestone.POSTPONED),
        ("Tentative Answer Key and Objection Tracker", ExamMilestone.ANSWER_KEY),
        ("Uploading of Response Sheets", ExamMilestone.ANSWER_KEY),
        ("Final Result with Category-wise Cut-off Marks", ExamMilestone.RESULT),
        ("Merit List of selected candidates", ExamMilestone.RESULT),
        ("Detailed Notification for recruitment", None),
    ],
)
def test_classify_milestone(text, milestone):
    assert classify_milestone(text) is milestone
