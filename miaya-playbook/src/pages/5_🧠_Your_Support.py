"""Your own support system."""
from __future__ import annotations

from datetime import datetime

import streamlit as st

from data import add_journal_entry, init_db, journal_entries

st.set_page_config(page_title="Your Support", page_icon="🧠", layout="wide")
init_db()

st.title("🧠 Your support")
st.caption("Doing this without your own support system is how people burn out.")

st.subheader("This week")
col1, col2 = st.columns(2)
with col1:
    st.markdown(
        """
        **NAMI Flagstaff Family Support Group** — peer-led, drop-in, free
        - Thursdays 5:30–7:00 PM
        - Hope Community Church, 3700 N. Fanning Drive, Flagstaff
        - (928) 214-2218 | flagnami@gmail.com
        """
    )
with col2:
    st.markdown(
        """
        **NAMI Caregiver HelpLine**
        - Call **(800) 950-6264**, press **4**
        - Or text **"Family" to 62640**
        - Mon–Fri 8am–8pm AZ time
        """
    )

st.divider()
st.subheader("Programs to enroll in")

st.markdown(
    """
    **NAMI Family-to-Family** — free 8-week course, evidence-based, taught by other family members.
    → [Register here](https://www.nami.org/program/nami-family-to-family/)

    **CPG-aware family advocate** — works with people from the Centennial Park / FLDS / fundamentalist community.
    - The Open Door (Tonia Tewell) — (801) 386-1077 | help@holdingouthelp.org
    - Cherish Families (Colorado City) — (928) 875-0969

    **Virtual peer groups** when in-person isn't possible:
    - DBSA Family & Friends — https://www.dbsalliance.org/support/chapters-and-support-groups/
    - SARDAA (psychosis-specific) — Sat 7pm ET / Sun 4pm ET — https://sczaction.org/peer-support-groups/
    """
)

st.divider()
st.subheader("Therapist directory — religious-trauma / former-fundamentalist-aware")
st.markdown(
    """
    St. George, UT (closest to Centennial Park):
    - Ryan Craig (LCSW)
    - Russell W. Talbot (LCSW)
    - Dani Green (AMFT)
    Search [Psychology Today St. George](https://www.psychologytoday.com/us/therapists/ut/saint-george) → filter trauma-informed + faith transitions.
    """
)

st.divider()
st.subheader("Journal — for you")
st.caption("Private. Not synced anywhere. Helpful to write what's happening, what you're feeling, what you need.")

with st.form("journal_form", clear_on_submit=True):
    title = st.text_input("Title", placeholder=datetime.now().strftime("%Y-%m-%d entry"))
    content = st.text_area("Entry", height=200)
    if st.form_submit_button("📝 Save entry"):
        if content.strip():
            add_journal_entry(title or datetime.now().strftime("%Y-%m-%d"), content)
            st.success("Saved.")
        else:
            st.warning("Empty entry — not saved.")

entries = journal_entries()
if entries:
    st.subheader("Previous entries")
    for e in entries:
        with st.expander(f"{e['entry_at']} — {e['title']}"):
            st.markdown(e["content"])

st.divider()
st.subheader("Reminders, for you")
st.markdown(
    """
    - Going to Thursday once doesn't commit you to anything.
    - You don't have to fix everything this week.
    - Miaya needs Future-You stable more than Present-You exhausted.
    - You can take care of her without taking care of Allen's response to her.
    - The system has paths that work without him. He's a choice, not a requirement.
    """
)
