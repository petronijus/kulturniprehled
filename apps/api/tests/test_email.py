"""SMTP digest relay adapter — message shape, transport selection, config guard."""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

import pytest

from kp_api.adapters.email import EmailNotConfigured, send_digest_email
from kp_api.config import Settings


def _settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = {
        "smtp_host": "smtp.example.com",
        "smtp_port": 587,
        "smtp_user": "relay@example.com",
        "smtp_password": "pw",
        "smtp_starttls": True,
        "digest_mail_from": "Kulturní přehled <from@example.com>",
        "digest_mail_to": "petronijus@example.com",
    }
    base.update(overrides)
    return Settings(**base)


@pytest.mark.asyncio
async def test_send_builds_html_and_relays_via_starttls() -> None:
    with patch("kp_api.adapters.email.smtplib.SMTP") as smtp_cls:
        smtp = smtp_cls.return_value.__enter__.return_value
        to = await send_digest_email(_settings(), "Týden CW24", "<h1>Ahoj</h1>")

    assert to == "petronijus@example.com"
    smtp.starttls.assert_called_once()
    smtp.login.assert_called_once_with("relay@example.com", "pw")
    smtp.send_message.assert_called_once()

    message = smtp.send_message.call_args.args[0]
    assert message["Subject"] == "Týden CW24"
    assert message["To"] == "petronijus@example.com"
    assert message["From"] == "Kulturní přehled <from@example.com>"
    html = message.get_body(preferencelist=("html",)).get_content()
    assert "<h1>Ahoj</h1>" in html


@pytest.mark.asyncio
async def test_send_uses_ssl_transport_when_starttls_disabled() -> None:
    with patch("kp_api.adapters.email.smtplib.SMTP_SSL") as smtp_cls:
        smtp = smtp_cls.return_value.__enter__.return_value
        await send_digest_email(_settings(smtp_starttls=False, smtp_port=465), "S", "<p>x</p>")

    smtp.send_message.assert_called_once()


@pytest.mark.asyncio
async def test_send_without_relay_raises_not_configured() -> None:
    with pytest.raises(EmailNotConfigured):
        await send_digest_email(_settings(smtp_host=""), "S", "<p>x</p>")
