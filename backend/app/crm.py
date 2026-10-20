import re
from datetime import datetime

from .db import Record


def validate_crm(kind, body, db):
    def reference(key, kinds):
        value = body.get(key, "")
        row = db.get(Record, value)
        if not row or row.deleted or row.kind not in kinds:
            raise ValueError("Invalid CRM reference")

    def date(key, required=False):
        value = body.get(key, "")
        if not value and not required:
            return
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError()
        except ValueError:
            raise ValueError("Invalid CRM date") from None

    if kind in {"crm_contacts", "crm_actions"}:
        if not body.get("title", "").strip() or len(body["title"]) > 500:
            raise ValueError("CRM title is required (maximum 500 characters)")
    if kind == "crm_contacts":
        if body.get("identityType") not in {"Company", "Individual"}:
            raise ValueError("Invalid CRM identity type")
        if body.get("contactType") not in {
            "Client",
            "Prospect",
            "Provider",
            "Simple contact",
        }:
            raise ValueError("Invalid CRM contact type")
        for key in ("phones", "mobiles", "whatsapp"):
            for number in body.get(key, "").splitlines():
                if number.strip() and not re.fullmatch(
                    r"\+[1-9][0-9]{6,14}", number.strip()
                ):
                    raise ValueError(
                        "CRM phone numbers must use international E.164 format"
                    )
    elif kind == "crm_actions":
        reference("contactID", {"crm_contacts"})
        if body.get("actionType") not in {
            "Phone call",
            "Email sent",
            "WhatsApp sent",
            "Invoice sent",
        }:
            raise ValueError("Invalid CRM action type")
        date("date", required=True)
        date("reminderDate")
    elif kind == "crm_attachments":
        reference("ownerID", {"crm_contacts", "crm_actions"})
        reference("fileID", {"files"})
    else:
        raise ValueError("Unknown CRM record kind")
