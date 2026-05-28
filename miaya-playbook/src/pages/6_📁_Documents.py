"""Document uploads."""
from __future__ import annotations

import os
from pathlib import Path

import streamlit as st

from data import db, init_db

st.set_page_config(page_title="Documents", page_icon="📁", layout="wide")
init_db()

UPLOAD_DIR = Path(os.environ.get("MIAYA_UPLOADS", "/data/uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

st.title("📁 Documents")
st.caption("Court paperwork, medical letters, attorney correspondence. Stored on the PVC. Backed up only as you back up the PVC.")

CATEGORIES = [
    "Court paperwork",
    "Medical / facility",
    "Attorney correspondence",
    "Insurance / AHCCCS",
    "SNT / estate planning",
    "Family / community",
    "Other",
]

st.subheader("Upload")
with st.form("upload_form", clear_on_submit=True):
    f = st.file_uploader(
        "Choose file",
        type=["pdf", "png", "jpg", "jpeg", "txt", "docx", "doc", "csv", "xlsx"],
    )
    cat = st.selectbox("Category", CATEGORIES)
    notes = st.text_input("Notes", placeholder="e.g. arraignment minute entry 2026-05-22")
    if st.form_submit_button("📤 Upload"):
        if f is not None:
            path = UPLOAD_DIR / f.name
            with open(path, "wb") as out:
                out.write(f.getbuffer())
            with db() as conn:
                conn.execute(
                    "INSERT INTO documents (filename, category, notes, file_path) VALUES (?, ?, ?, ?)",
                    (f.name, cat, notes, str(path)),
                )
            st.success(f"Uploaded {f.name}")
        else:
            st.warning("No file selected")

st.divider()
st.subheader("Library")

with db() as conn:
    rows = conn.execute(
        "SELECT * FROM documents ORDER BY uploaded_at DESC"
    ).fetchall()

if not rows:
    st.info("No documents yet.")
else:
    cat_filter = st.multiselect("Filter category", CATEGORIES, default=CATEGORIES)
    for r in rows:
        if r["category"] not in cat_filter:
            continue
        with st.expander(f"📄 {r['filename']} — {r['category']} — {r['uploaded_at']}"):
            st.markdown(f"**Notes:** {r['notes'] or '_none_'}")
            try:
                with open(r["file_path"], "rb") as fh:
                    st.download_button(
                        "⬇ Download",
                        fh,
                        file_name=r["filename"],
                        key=f"dl_{r['id']}",
                    )
            except FileNotFoundError:
                st.error("File missing from disk.")
            if st.button("🗑 Delete record", key=f"del_{r['id']}"):
                with db() as conn:
                    conn.execute("DELETE FROM documents WHERE id = ?", (r["id"],))
                try:
                    Path(r["file_path"]).unlink(missing_ok=True)
                except Exception:
                    pass
                st.rerun()
