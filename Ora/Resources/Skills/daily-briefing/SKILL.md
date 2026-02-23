---
name: Daily Briefing
description: Summarizes today's calendar events, pending reminders, and any flagged contacts into a spoken morning briefing.
version: 1.0.0
---

# Daily Briefing

Use this skill when the user asks for a morning brief, daily rundown, or end-to-end overview of today's commitments.

## Procedure

1. Call `calendar.query` for today's date window in the user's local timezone.
2. Call `reminders.list` filtered to items due today.
3. If calendar events include people the user may need to reach, optionally call `contacts.search` for those names.
4. Compose a concise spoken summary:
   - Start with total events and first upcoming event time.
   - Mention important reminders due today.
   - Mention any key contact detail only if it helps the day plan.
5. Keep the final response short and voice-friendly.

## Output style

- Prefer clear time blocks (morning, afternoon, evening).
- If nothing is scheduled, say that explicitly and suggest one helpful next step.
