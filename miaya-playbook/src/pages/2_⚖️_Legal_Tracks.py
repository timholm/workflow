"""Legal decision tree."""
from __future__ import annotations

import streamlit as st

from data import get_fact, init_db, set_fact

st.set_page_config(page_title="Legal Tracks", page_icon="⚖️", layout="wide")
init_db()

st.title("⚖️ Legal tracks")
st.caption("Three intersecting decisions: criminal case, capacity / decision-making, financial structure.")

st.subheader("Inputs")
with st.form("legal_inputs", border=False):
    col1, col2, col3 = st.columns(3)
    with col1:
        charge_type = st.selectbox(
            "Charge type",
            [
                "unknown",
                "non-violent misdemeanor",
                "non-violent felony",
                "violent felony",
                "drug possession",
                "weapons",
                "DUI / traffic",
                "other",
            ],
            index=["unknown", "non-violent misdemeanor", "non-violent felony", "violent felony", "drug possession", "weapons", "DUI / traffic", "other"].index(
                get_fact("charge_type", "unknown")
            ),
        )
    with col2:
        smi_qualifying = st.selectbox(
            "SMI-qualifying diagnosis",
            ["unknown", "yes (schizophrenia / bipolar I / psychotic features)", "no", "pending evaluation"],
            index=["unknown", "yes (schizophrenia / bipolar I / psychotic features)", "no", "pending evaluation"].index(
                get_fact("smi_qualifying", "unknown")
            ),
        )
    with col3:
        lucid = st.selectbox(
            "Capacity to sign documents now",
            ["unknown", "lucid intervals — can sign", "not lucid", "improving with treatment"],
            index=["unknown", "lucid intervals — can sign", "not lucid", "improving with treatment"].index(
                get_fact("lucid", "unknown")
            ),
        )
    if st.form_submit_button("Save inputs"):
        set_fact("charge_type", charge_type)
        set_fact("smi_qualifying", smi_qualifying)
        set_fact("lucid", lucid)
        st.success("Saved.")

st.divider()

# --- Criminal track ---
st.subheader("1. Criminal case track")

if charge_type in ("violent felony", "weapons"):
    st.warning(
        "Mental Health Court diversion likely **disqualified** for this charge type. "
        "Pursue Rule 11 (competency) and negotiate a mental-health-conditioned plea."
    )
    st.markdown(
        """
        **Path:** Rule 11 competency motion → state hospital restoration if incompetent → plea negotiation with treatment conditions.
        - File via defense attorney (private: Griffen & Stevens, or PD's office)
        - A.R.S. § 13-4517 may trigger guardian-ad-litem appointment
        """
    )
elif charge_type in ("non-violent misdemeanor", "non-violent felony", "drug possession", "DUI / traffic"):
    if smi_qualifying.startswith("yes"):
        st.success(
            "**Strong candidate for Coconino County Mental Health Court diversion.** Call (928) 679-7580."
        )
    elif smi_qualifying == "pending evaluation":
        st.info(
            "Start SMI evaluation immediately — Southwest Behavioral (855) 832-2866. "
            "Once SMI status confirmed, MHC becomes available."
        )
    else:
        st.info(
            "Non-MHC track: standard defense with mental-health mitigation. Negotiate treatment-in-lieu-of-incarceration if possible."
        )
    st.markdown(
        """
        **Program structure (if accepted):**
        - 14+ months under Judge Joshua Steinlage (Division VII)
        - Regular court appearances
        - Treatment compliance + drug testing
        - Charges dismissed or reduced on graduation
        - AHCCCS covers treatment (via Care1st / AZ Complete Health)
        """
    )
else:
    st.caption("Set the charge type above for tailored guidance.")

st.divider()

# --- Capacity track ---
st.subheader("2. Capacity / decision-making track")

if lucid == "lucid intervals — can sign":
    st.success(
        "**Best path: Mental Health Power of Attorney (A.R.S. § 36-3281).** "
        "$0–500, immediate. Courts won't appoint a guardian if a valid POA exists."
    )
    st.markdown(
        """
        **Steps:**
        1. Download AZ Mental Health Care POA form
        2. Notarize during a lucid window (virtual notary works)
        3. File copy with The Guidance Center / treating provider
        4. Skip guardianship entirely
        """
    )
elif lucid == "not lucid":
    st.warning(
        "Mental Health POA not viable. Consider **limited guardianship** "
        "(scope = medical decisions only) or wait for Rule 11 to trigger § 13-4517."
    )
    st.markdown(
        """
        **Options ranked:**
        1. **Wait for Rule 11 incompetency finding** → A.R.S. § 13-4517 guardian-ad-litem (free probate runway)
        2. **Limited guardianship** — Coconino Probate (928) 679-7600, ~$191, 60–90 days
        3. **Full guardianship + conservatorship** — if she also has assets to manage
        4. **Public Fiduciary (Rashida Suminski)** — court-appointed if family unavailable
        """
    )
elif lucid == "improving with treatment":
    st.info(
        "Wait 2–4 weeks. Get her stabilized first, then attempt the Mental Health POA route."
    )
else:
    st.caption("Set her capacity status above for tailored guidance.")

st.divider()

# --- Financial track ---
st.subheader("3. Financial track (if Allen funds care)")
st.markdown(
    """
    **Goal:** Allen's money supports Miaya without disqualifying her from AHCCCS / SSI / SSDI.

    **Vehicle: Third-Party Special Needs Trust (SNT)**
    - Funded by Allen (or any family member) — **no Medicaid payback at death**
    - Trustee separate from guardian — can have both
    - Setup cost $2K–$5K
    - Corporate trustee $6K–$12K/year

    **Recommended attorneys:**
    - Bivens & Associates (Scottsdale) — (480) 922-1010 — free initial consult
    - JacksonWhite Law — (480) 660-3938
    - PLAN of Arizona Pooled Trust — (602) 759-8180 — $5K minimum, professional trustee included (cheapest entry)

    **ABLE account** — supplemental savings vehicle ($18K/yr limit). Pair with SNT.
    """
)

st.divider()

st.subheader("Summary decision tree")
st.markdown(
    """
    ```
    ┌─ Criminal case
    │  ├─ Non-violent + SMI → Mental Health Court diversion (14+ mo, charges dismissed)
    │  └─ Violent / disqualifying → Rule 11 + plea negotiation
    │
    ├─ Capacity
    │  ├─ Lucid → Mental Health POA (skip guardianship)
    │  └─ Not lucid → Rule 11 → § 13-4517 guardian ad litem  OR  limited guardianship
    │
    └─ Money
       └─ Third-party SNT funded by Allen → corporate trustee → preserves benefits
    ```
    """
)
