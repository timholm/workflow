"""Residential placement comparison."""
from __future__ import annotations

import streamlit as st

from data import init_db

st.set_page_config(page_title="Treatment Options", page_icon="🏥", layout="wide")
init_db()

st.title("🏥 Treatment options")
st.caption("Residential placements + step-down. Costs assume private pay; many take AHCCCS once SMI is designated.")

PLACEMENTS = [
    {
        "name": "Sierra Tucson",
        "location": "Tucson, AZ",
        "phone": "(855) 578-0241",
        "url": "https://www.sierratucson.com/",
        "specialty": "Dual diagnosis, trauma, mood, addiction",
        "length": "30–60 days customizable",
        "cost_30d": "$40K–$60K",
        "court_ordered": "Yes (private)",
        "notes": "Newsweek #1 addiction treatment 3 yrs running. 34K+ residents treated since 1984.",
    },
    {
        "name": "Cottonwood Tucson",
        "location": "Tucson, AZ",
        "phone": "(888) 727-0441",
        "url": "https://cottonwooddetucson.com/",
        "specialty": "Dual diagnosis (mental health + substance)",
        "length": "5-day intensive assessment + 30+ days residential",
        "cost_30d": "$30K–$50K",
        "court_ordered": "Yes",
        "notes": "Detox + residential + IOP/PHP. Veteran program. Family programs.",
    },
    {
        "name": "Decision Point Center",
        "location": "Prescott, AZ",
        "phone": "(844) 292-5010",
        "url": "https://www.decisionpointcenter.com/",
        "specialty": "Dual diagnosis, trauma/PTSD, gender-specific",
        "length": "14–90 days (typically 30)",
        "cost_30d": "$30K–$60K",
        "court_ordered": "Discretionary",
        "notes": "Joint Commission accredited. Gender-specific homes.",
    },
    {
        "name": "Seaglass Recovery",
        "location": "Prescott, AZ",
        "phone": "via website",
        "url": "https://seaglassrecoveryarizona.com/",
        "specialty": "Women-only, dual diagnosis",
        "length": "2-week or 30-day",
        "cost_30d": "Contact",
        "court_ordered": "Inquire",
        "notes": "20 beds. Semi-private rooms. Holistic care included.",
    },
    {
        "name": "Calvary Healing Center",
        "location": "Phoenix, AZ",
        "phone": "(888) 492-5113",
        "url": "https://calvarycenter.com/",
        "specialty": "Dual diagnosis, women's program, trauma",
        "length": "30+ days",
        "cost_30d": "$25K–$45K",
        "court_ordered": "Inquire",
        "notes": "50-bed facility. Faith-friendly. Free assessment.",
    },
    {
        "name": "ViewPoint Dual Recovery",
        "location": "Prescott, AZ",
        "phone": "(928) 910-8853",
        "url": "https://www.viewpointdualrecovery.com/",
        "specialty": "Women-only support, trauma",
        "length": "Varies",
        "cost_30d": "Insurance + private pay",
        "court_ordered": "Inquire",
        "notes": "Equine, yoga, art, music therapy. Relapse prevention.",
    },
    {
        "name": "AZ Women's Recovery Center",
        "location": "Phoenix / Glendale, AZ",
        "phone": "via website",
        "url": "https://azwomensrecoverycenter.org/",
        "specialty": "Women-focused nonprofit",
        "length": "Residential + outpatient",
        "cost_30d": "Sliding scale",
        "court_ordered": "Yes",
        "notes": "Est. 1960 (NCADD lineage). Multiple locations.",
    },
    {
        "name": "Avalon Malibu",
        "location": "Malibu, CA",
        "phone": "via website",
        "url": "https://www.avalonmalibu.com/",
        "specialty": "Dual diagnosis, psychiatric, trauma",
        "length": "Customizable",
        "cost_30d": "$50K–$80K+",
        "court_ordered": "Yes",
        "notes": "Luxury option. 6:1 staff-to-patient. Court-ordered cases accepted.",
    },
    {
        "name": "Short Creek Dream Center",
        "location": "Hildale, UT",
        "phone": "via website",
        "url": "https://www.shortcreekdreamcenter.org/",
        "specialty": "CPG / fundamentalist-Mormon community-aware",
        "length": "40-bed residential, varies",
        "cost_30d": "Donation-based",
        "court_ordered": "Likely no",
        "notes": "Inside the community. Trauma-informed care for fundamentalist survivors.",
    },
]

import pandas as pd

df = pd.DataFrame(PLACEMENTS)
st.dataframe(
    df,
    use_container_width=True,
    hide_index=True,
    column_config={
        "url": st.column_config.LinkColumn("Website", display_text="link"),
        "name": "Facility",
        "location": "Location",
        "phone": "Phone",
        "specialty": "Specialty",
        "length": "Length",
        "cost_30d": "Cost / 30d",
        "court_ordered": "Court-ordered?",
        "notes": "Notes",
    },
)

st.divider()
st.subheader("Filtering questions to ask each facility")
st.markdown(
    """
    1. Do you accept patients with pending criminal charges? (Critical — many luxury programs decline.)
    2. Do you accept Title 36 court-ordered patients?
    3. What's your specific approach to plural-marriage / closed-religious-community trauma?
    4. Do you bill AHCCCS for SMI-designated patients, or only private pay?
    5. What does a typical day look like? (Compares program structures.)
    6. What's the family contact / visitation policy in the first 14 days?
    7. What's the discharge plan / step-down arrangement?
    """
)

st.divider()
st.subheader("Step-down ladder")
st.markdown(
    """
    1. **Acute inpatient** — Guidance Center (current). 3–7 days.
    2. **Residential** — Sierra Tucson / Decision Point / Cottonwood. 30–90 days.
    3. **PHP (Partial Hospitalization)** — 6 hrs/day, 5 days/week. ~30 days.
    4. **IOP (Intensive Outpatient)** — 3 hrs/day, 3 days/week. 8–12 weeks.
    5. **Outpatient + ACT team + supportive housing** — long-term wraparound (AHCCCS-funded with SMI).
    """
)
