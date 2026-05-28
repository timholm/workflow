"""Budget builder for the Allen conversation."""
from __future__ import annotations

import streamlit as st

from contacts import ASK_ALLEN_DEFAULT_ITEMS
from data import ask_items, get_fact, init_db, set_fact, upsert_ask_item

st.set_page_config(page_title="Ask Allen", page_icon="💰", layout="wide")
init_db()

st.title("💰 Ask Allen — funding conversation")
st.caption("Build the specific number. Don't walk in with an open-ended ask.")

# Seed defaults once
existing = {row["item"]: row for row in ask_items()}
if not existing:
    for item, amount, included in ASK_ALLEN_DEFAULT_ITEMS:
        upsert_ask_item(item, amount, included, "")
    existing = {row["item"]: row for row in ask_items()}

st.subheader("Budget items")
total = 0.0
included_lines: list[str] = []
with st.form("budget_form", border=False):
    for item, default_amount, default_included in ASK_ALLEN_DEFAULT_ITEMS:
        cur = existing.get(item)
        cur_amount = cur["amount"] if cur else default_amount
        cur_included = bool(cur["included"]) if cur else default_included
        cur_notes = (cur["notes"] if cur and cur["notes"] else "") if cur else ""
        col1, col2, col3, col4 = st.columns([4, 1, 2, 3])
        with col1:
            st.markdown(item)
        with col2:
            included = st.checkbox(
                "Include", value=cur_included, key=f"inc_{item}", label_visibility="collapsed"
            )
        with col3:
            amount = st.number_input(
                "USD",
                min_value=0.0,
                value=float(cur_amount),
                step=500.0,
                key=f"amt_{item}",
                label_visibility="collapsed",
            )
        with col4:
            notes = st.text_input(
                "Notes",
                value=cur_notes,
                key=f"nt_{item}",
                label_visibility="collapsed",
                placeholder="provider / decision",
            )
        if included:
            total += amount
            included_lines.append(f"- **{item}** — ${amount:,.0f}" + (f" ({notes})" if notes else ""))
        upsert_ask_item(item, amount, included, notes)
    submit = st.form_submit_button("💾 Save & recalc", use_container_width=True)

st.divider()
col_t1, col_t2 = st.columns(2)
with col_t1:
    st.metric("**Total ask to Allen**", f"${total:,.0f}")
with col_t2:
    st.metric("Included items", len(included_lines))

st.divider()

# --- The message draft ---
st.subheader("📝 Conversation framing")
st.caption("Edit and keep here. When ready, send via the channel you usually reach him.")

template = f"""Allen,

I need 20 minutes. It's about Miaya. She's at {get_fact('facility', '[facility]')} in Flagstaff — arrested {get_fact('arrest_date', '[date]')} on {get_fact('charges', '[charges]')}. She's in crisis but stabilizing.

Here's what I have lined up so she comes out of this with the best possible outcome:

{chr(10).join(included_lines) if included_lines else '[items will appear here once you check them above]'}

**Total: ${total:,.0f}**

The path I'm pursuing:
1. SMI designation through Southwest Behavioral — already in motion (~10 days)
2. Coconino Mental Health Court diversion (Judge Steinlage, Division VII) — if she qualifies, charges dismissed in 14+ months
3. Third-party Special Needs Trust funded by you — so this doesn't disqualify her from AHCCCS/SSI down the line
4. Residential placement once she's discharged from acute care

I've got providers identified for every line. I just need the funding. I'd rather we handle this quietly as a family than have it become a court-appointed-fiduciary situation.

When can we talk?

— [you]
"""
st.text_area("Draft", value=template, height=400, key="message_draft")

st.divider()
st.subheader("Status & log")
allen_status = st.selectbox(
    "Where are you in the conversation?",
    [
        "Not yet approached",
        "Message drafted",
        "Sent — awaiting response",
        "Talked — considering",
        "Yes — funds incoming",
        "Yes — partial",
        "No",
        "Refused / no contact",
    ],
    index=0,
)
if st.button("Save status"):
    set_fact("allen_status", allen_status)
    st.success("Saved.")

st.divider()
st.subheader("If he says no — backup plan")
st.markdown(
    """
    **You have a complete safety net at ~$0 out-of-pocket:**
    - DNA-People's Legal Services (free legal aid) (928) 774-0653
    - Coconino Public Defender (929) 679-7700
    - SMI designation → AHCCCS-funded behavioral health (incl. ACT team, residential, supportive housing)
    - Mental Health Court (treatment paid by AHCCCS)
    - Public Fiduciary if guardianship needed
    - NAMI Family-to-Family for your own support

    **Other family members to ask before going public-resources-only:**
    - Joseph C. Knudson (HHM)
    - Kenneth Knudson (PRMI)
    - Paul Knudson (PRMI Centennial Park)
    - Any of the other 14 / 8 siblings you have relationships with
    """
)
