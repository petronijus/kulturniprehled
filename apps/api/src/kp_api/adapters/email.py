"""SMTP relay for the weekly digest email.

The cloud Gmail connector can only create drafts, so the digest routine
hands its finished HTML to `POST /v1/digest/send` and the backend relays
it over SMTP. Provider-agnostic — the env points `smtp_host` at a
transactional relay, a self-hosted server, or plain provider SMTP; the code
is the same. Production uses Resend, which authenticates as the literal
username "resend" with the API key as the password.

`smtplib` is synchronous, so the send runs in a worker thread to keep the
request handler off the event loop (the project forbids blocking calls in
async paths).
"""

from __future__ import annotations

import asyncio
import logging
import smtplib
import ssl
from email.message import EmailMessage

from kp_api.config import Settings

logger = logging.getLogger(__name__)


class EmailNotConfigured(Exception):
    """No SMTP relay is configured — the send endpoint should 503."""


class EmailSendError(Exception):
    """The SMTP relay rejected or dropped the message."""


def _build_message(from_addr: str, to_addr: str, subject: str, html_body: str) -> EmailMessage:
    message = EmailMessage()
    message["From"] = from_addr
    message["To"] = to_addr
    message["Subject"] = subject
    # A text/plain part keeps spam filters happy and gives non-HTML clients
    # something readable; the HTML alternative is the real digest.
    message.set_content("Tento e-mail je ve formátu HTML — otevři ho v klientu s podporou HTML.")
    message.add_alternative(html_body, subtype="html")
    return message


def _send_sync(settings: Settings, message: EmailMessage) -> None:
    context = ssl.create_default_context()
    if settings.smtp_starttls:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=30) as smtp:
            smtp.starttls(context=context)
            if settings.smtp_user:
                smtp.login(settings.smtp_user, settings.smtp_password)
            smtp.send_message(message)
    else:
        with smtplib.SMTP_SSL(
            settings.smtp_host, settings.smtp_port, timeout=30, context=context
        ) as smtp:
            if settings.smtp_user:
                smtp.login(settings.smtp_user, settings.smtp_password)
            smtp.send_message(message)


async def send_digest_email(settings: Settings, subject: str, html_body: str) -> str:
    """Relay the rendered digest to the single configured recipient.

    Returns the recipient address on success. Raises `EmailNotConfigured`
    when no relay is set up, or `EmailSendError` on any SMTP failure.
    """

    if not settings.smtp_host or not settings.digest_mail_from or not settings.digest_mail_to:
        raise EmailNotConfigured("SMTP relay is not configured")

    message = _build_message(settings.digest_mail_from, settings.digest_mail_to, subject, html_body)
    try:
        await asyncio.to_thread(_send_sync, settings, message)
    except Exception as exc:
        logger.warning("Digest email relay failed", exc_info=True)
        raise EmailSendError(str(exc)) from exc

    return settings.digest_mail_to
