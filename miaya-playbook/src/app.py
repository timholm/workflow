"""Miaya — crisis playbook. Entry point."""
from __future__ import annotations

import streamlit as st

from contacts import CONTACTS, STATUS_LABELS
from data import all_calls, get_fact, init_db, set_fact

st.set_page_config(
    page_title="Miaya — playbook",
    page_icon="🛟",
    layout="wide",
    initial_sidebar_state="expanded",
)

init_db()


def _stat(label: str, value: str | int) -> None:
    st.metric(label, value)


st.title("Miaya — crisis playbook")
st.caption("Private. Personal. One step at a time.")

calls = {row["contact_key"]: row for row in all_calls()}
total = len(CONTACTS)
completed = sum(1 for c in CONTACTS if (calls.get(c["key"]) or {})["status"] == "completed") if calls else 0
in_progress = sum(
    1
    for c in CONTACTS
    if (calls.get(c["key"]) or {})["status"]
    in ("reached_in_progress", "callback_scheduled", "voicemail_left")
) if calls else 0
not_started = total - sum(
    1 for c in CONTACTS if c["key"] in calls and calls[c["key"]]["status"] != "not_started"
)

c1, c2, c3, c4 = st.columns(4)
with c1:
    _stat("Total contacts", total)
with c2:
    _stat("✅ Completed", completed)
with c3:
    _stat("🟡 In progress", in_progress)
with c4:
    _stat("🔘 Not started", not_started)

st.divider()

# --- Top-of-mind facts ---
st.subheader("Top-of-mind facts (update as you learn)")
with st.form("facts_form", border=False):
    fc1, fc2 = st.columns(2)
    with fc1:
        facility = st.text_input(
            "Confirmed facility she's at",
            value=get_fact("facility", "The Guidance Center (assumed)"),
        )
        case_no = st.text_input("Case number", value=get_fact("case_no"))
        charges = st.text_input("Charges", value=get_fact("charges"))
        hearing = st.text_input("Next hearing date", value=get_fact("hearing"))
    with fc2:
        attorney = st.text_input("Attorney of record", value=get_fact("attorney"))
        smi_status = st.text_input(
            "SMI designation status", value=get_fact("smi_status", "Not started")
        )
        ahcccs_status = st.text_input(
            "AHCCCS application status", value=get_fact("ahcccs_status", "Not started")
        )
        allen_status = st.text_input(
            "Allen conversation status", value=get_fact("allen_status", "Not approached")
        )
    if st.form_submit_button("Save"):
        set_fact("facility", facility)
        set_fact("case_no", case_no)
        set_fact("charges", charges)
        set_fact("hearing", hearing)
        set_fact("attorney", attorney)
        set_fact("smi_status", smi_status)
        set_fact("ahcccs_status", ahcccs_status)
        set_fact("allen_status", allen_status)
        st.success("Saved.")

st.divider()

# --- The 4 most urgent calls ---
st.subheader("📞 Make these calls first")

urgent = [c for c in CONTACTS if c["priority"] == 1]
for c in urgent:
    state = calls.get(c["key"])
    status = state["status"] if state else "not_started"
    cols = st.columns([3, 2, 2, 3])
    with cols[0]:
        st.markdown(f"**{c['name']}**")
        st.caption(c["purpose"])
    with cols[1]:
        st.code(c["phone"], language=None)
    with cols[2]:
        st.markdown(STATUS_LABELS.get(status, status))
    with cols[3]:
        if state and state["notes"]:
            st.caption(state["notes"])
        st.page_link(
            "pages/1_📞_Call_Tracker.py",
            label="→ Update in Call Tracker",
            use_container_width=True,
        )

st.divider()

# --- Crisis hotlines ---
st.subheader("🚨 If she's in immediate danger")
ch1, ch2, ch3 = st.columns(3)
with ch1:
    st.markdown("**988** — National Suicide & Crisis Lifeline (call/text)")
with ch2:
    st.markdown("**1-877-756-4090** — AZ N. region 24/7 crisis")
with ch3:
    st.markdown("**1-844-534-HOPE** — AZ statewide crisis line")

st.divider()

with st.expander("Use the sidebar to navigate. Pages:"):
    st.markdown(
        """
        - 📞 **Call Tracker** — log each call, status, notes
        - ⚖️ **Legal Tracks** — Mental Health Court vs Rule 11 vs POA vs guardianship
        - 🏥 **Treatment Options** — residential placement comparison
        - 💰 **Ask Allen** — budget builder for the funding conversation
        - 🧠 **Your Support** — NAMI, Open Door, peer groups
        - 📁 **Documents & Journal** — uploads + notes
        """
    )
