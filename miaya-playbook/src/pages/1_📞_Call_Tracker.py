"""Phone tree tracker."""
from __future__ import annotations

from datetime import date

import streamlit as st

from contacts import CATEGORIES, CONTACTS, STATUS_LABELS, STATUSES, by_key
from data import call_history, get_call, init_db, log_call, upsert_call

st.set_page_config(page_title="Call Tracker", page_icon="📞", layout="wide")
init_db()

st.title("📞 Call tracker")
st.caption("Each contact, current status, history.")

cat_filter = st.multiselect("Filter by category", CATEGORIES, default=CATEGORIES)

for c in sorted(CONTACTS, key=lambda x: (x["priority"], x["name"])):
    if c["category"] not in cat_filter:
        continue
    state = get_call(c["key"])
    current_status = state["status"] if state else "not_started"
    badge = STATUS_LABELS.get(current_status, current_status)

    with st.expander(f"P{c['priority']} · {badge} · **{c['name']}** — {c['phone']}"):
        col_a, col_b = st.columns([2, 3])
        with col_a:
            st.markdown(f"**Phone:** `{c['phone']}`")
            if "alt_phone" in c:
                st.markdown(f"**Alt:** `{c['alt_phone']}`")
            if "email" in c:
                st.markdown(f"**Email:** {c['email']}")
            if "address" in c:
                st.markdown(f"**Address:** {c['address']}")
            if "url" in c:
                st.markdown(f"[Web]({c['url']})")
            st.markdown(f"*Category:* {c['category']}")
        with col_b:
            st.markdown(f"**Purpose:** {c['purpose']}")

        st.markdown("---")
        with st.form(f"form_{c['key']}", border=False):
            fcol1, fcol2 = st.columns(2)
            with fcol1:
                new_status = st.selectbox(
                    "Status",
                    STATUSES,
                    index=STATUSES.index(current_status) if current_status in STATUSES else 0,
                    format_func=lambda s: STATUS_LABELS.get(s, s),
                    key=f"st_{c['key']}",
                )
                answered_by = st.text_input(
                    "Answered by / spoke with",
                    value=(state["answered_by"] if state else "") or "",
                    key=f"ans_{c['key']}",
                )
                next_action = st.text_input(
                    "Next action",
                    value=(state["next_action"] if state else "") or "",
                    key=f"na_{c['key']}",
                )
                next_action_at = st.date_input(
                    "Next action by",
                    value=date.fromisoformat(state["next_action_at"])
                    if state and state["next_action_at"]
                    else None,
                    key=f"nad_{c['key']}",
                )
            with fcol2:
                notes = st.text_area(
                    "Notes",
                    value=(state["notes"] if state else "") or "",
                    height=180,
                    key=f"nt_{c['key']}",
                )
            scol1, scol2 = st.columns(2)
            with scol1:
                save = st.form_submit_button("💾 Save", use_container_width=True)
            with scol2:
                log = st.form_submit_button(
                    "📝 Save + log call attempt", use_container_width=True
                )

            if save or log:
                upsert_call(
                    c["key"],
                    status=new_status,
                    answered_by=answered_by,
                    notes=notes,
                    next_action=next_action,
                    next_action_at=next_action_at.isoformat()
                    if next_action_at
                    else None,
                    last_called_at=(
                        None
                        if new_status == "not_started"
                        else __import__("datetime").datetime.now().isoformat()
                    ),
                )
                if log:
                    log_call(c["key"], new_status, notes)
                st.success("Saved." + (" Logged call attempt." if log else ""))
                st.rerun()

        hist = call_history(c["key"])
        if hist:
            st.markdown("**History**")
            for h in hist[:5]:
                st.caption(
                    f"{h['called_at']} — {STATUS_LABELS.get(h['outcome'], h['outcome'])}"
                    + (f" — {h['notes']}" if h["notes"] else "")
                )
