"""
AI Categorizer — uses Claude to understand what Tim said and what to do with it.

Categories:
    task       — "Call Mike about the truck" → goes to task list on print
    calendar   — "Cancel Thursday evening" → calendar action
    journal    — "Feeling good about the garden" → journal section
    email      — "Reply to Sarah, tell her yes" → draft and send email
    shopping   — "Buy more 5-gallon buckets" → shopping list
    note       — general thought worth keeping
    conversation — Tim's side of a conversation (context for the model)
    discard    — filler, background, not useful
"""

import os
import json
from anthropic import Anthropic


CATEGORIZATION_PROMPT = """You are part of Tim's life automation system. Tim wears a microphone 24/7
and only his voice is captured (other people's voices are discarded on-device).

Your job: read a transcription of something Tim said and categorize it.

Return JSON with:
- "category": one of [task, calendar, journal, email, shopping, note, conversation, discard]
- "summary": 1 sentence summary of what Tim said/wants
- "action": what the system should do (null if no action needed)
- "priority": "high", "medium", or "low"
- "contacts": list of any people mentioned by name

ONLY return the JSON object. No other text.

Examples:

Input: "I need to call Mike about picking up that truck on Saturday"
Output: {"category": "task", "summary": "Call Mike about truck pickup Saturday", "action": "Add to task list: Call Mike re: truck Saturday", "priority": "medium", "contacts": ["Mike"]}

Input: "Cancel everything Thursday evening I need a rest day"
Output: {"category": "calendar", "summary": "Cancel Thursday evening plans for rest", "action": "Cancel all Thursday evening calendar events", "priority": "high", "contacts": []}

Input: "Man the garden is really coming in nice this year, the tomatoes are huge"
Output: {"category": "journal", "summary": "Garden doing well, tomatoes growing large", "action": null, "priority": "low", "contacts": []}

Input: "Reply to Sarah's email tell her yes for Saturday and ask what to bring"
Output: {"category": "email", "summary": "Confirm Saturday with Sarah, ask what to bring", "action": "Draft email to Sarah: confirm Saturday, ask what to bring", "priority": "medium", "contacts": ["Sarah"]}

Input: "yeah so we went down to the beach and"
Output: {"category": "conversation", "summary": "Telling someone about going to the beach", "action": null, "priority": "low", "contacts": []}

Input: "um uh hmm"
Output: {"category": "discard", "summary": "Filler words, no content", "action": null, "priority": "low", "contacts": []}
"""


class Categorizer:
    def __init__(self):
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if api_key:
            self.client = Anthropic(api_key=api_key)
        else:
            self.client = None
            print("[Categorizer] WARNING: No ANTHROPIC_API_KEY set. Categorization disabled.")

    def categorize(self, text: str) -> dict:
        """Categorize a transcription segment using Claude."""
        if not self.client:
            return {"category": "note", "summary": text[:100], "action": None, "priority": "low", "contacts": []}

        if not text or len(text.strip()) < 3:
            return {"category": "discard", "summary": "", "action": None, "priority": "low", "contacts": []}

        try:
            response = self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=256,
                system=CATEGORIZATION_PROMPT,
                messages=[{"role": "user", "content": text}],
            )

            result_text = response.content[0].text.strip()
            return json.loads(result_text)

        except json.JSONDecodeError:
            return {"category": "note", "summary": text[:100], "action": None, "priority": "low", "contacts": []}
        except Exception as e:
            print(f"[Categorizer] Error: {e}")
            return {"category": "note", "summary": text[:100], "action": None, "priority": "low", "contacts": []}
