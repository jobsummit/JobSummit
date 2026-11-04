"""What a notice announces, from its title: admit card, exam date (or a
postponement), answer key or result. The app's exam watcher has its own copy
(mobile/lib/domain/exam_watcher.dart); this one sorts notices.json.
"""

from __future__ import annotations

import re

from app.domain.enums import ExamMilestone


def _phrases(*words: str) -> re.Pattern[str]:
    return re.compile(r"\b(?:" + "|".join(words) + r")\b", re.IGNORECASE)


# Checked in order, first match wins: the most specific / latest stage first,
# so "Result along with Final Answer Key" is a result.
MILESTONE_PATTERNS: tuple[tuple[ExamMilestone, re.Pattern[str]], ...] = (
    (ExamMilestone.POSTPONED, _phrases(r"postpone\w*", r"re-?scheduled?", r"deferred", r"cancell?ed")),
    (
        ExamMilestone.RESULT,
        _phrases(
            r"results?",
            r"merit lists?",
            r"select(?:ion)? lists?",
            r"cut[- ]?offs?",
            r"score ?cards?",
            r"final selection",
            r"marks of (?:the )?candidates",
        ),
    ),
    (
        ExamMilestone.ANSWER_KEY,
        _phrases(
            r"answer keys?",
            r"(?:provisional|tentative) keys?",
            r"response sheets?",
            r"objection\w*",
            r"question papers?",
        ),
    ),
    (
        ExamMilestone.ADMIT_CARD,
        _phrases(
            r"e-?admit cards?", r"admit cards?", r"hall tickets?", r"call letters?", r"admission certificate"
        ),
    ),
    (
        ExamMilestone.EXAM_SCHEDULE,
        _phrases(
            r"exam(?:ination)? dates?",
            r"dates? of (?:the )?exam(?:ination)?",
            r"exam(?:ination)? schedule",
            r"schedule of (?:the )?exam(?:ination)?",
            r"exam(?:ination)? calendar",
            r"exam city",
            r"city intimation",
            r"intimation slip",
            r"time ?table",
        ),
    ),
)


def classify_milestone(text: str) -> ExamMilestone | None:
    return next((m for m, pattern in MILESTONE_PATTERNS if pattern.search(text)), None)
