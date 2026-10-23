"""Enter Yandex credentials on the VPS without shell history or sending mail."""
import getpass
import os
from pathlib import Path
import smtplib
import ssl

import bootstrap


def main():
    if Path(bootstrap.__file__).with_name('runtime').joinpath('stand.env').exists():
        raise SystemExit('Configuration already exists; refusing to replace server secrets')
    address = input('Yandex email address: ').strip()
    if '@' not in address or not address.isascii() or not address.isprintable() or any(c.isspace() for c in address):
        raise SystemExit('Enter the full Yandex email address using ASCII characters without spaces')
    password = getpass.getpass('Yandex app password (hidden): ')
    if not password:
        raise SystemExit('An app password is required')
    if not password.isascii() or not password.isprintable() or any(c.isspace() for c in password):
        raise SystemExit(
            'Invalid app password input: copy only the password from Yandex, '
            'without quotes, spaces, Cyrillic letters or terminal prompt characters. '
            'Nothing was sent to Yandex and server secrets were not created.'
        )
    try:
        with smtplib.SMTP('smtp.yandex.ru', 587, timeout=20) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(address, password)
    except smtplib.SMTPAuthenticationError as error:
        # Do not print the raw SMTP reply: providers may echo authentication data.
        raise SystemExit(
            f'Yandex authentication failed (SMTP {error.smtp_code}). '
            'Use a Mail app password, not the account password. Enable app passwords '
            'in Yandex Mail settings. A newly created app password may take 2-3 hours '
            'to become active; keep it and retry later.'
        ) from None
    except (OSError, smtplib.SMTPException) as error:
        raise SystemExit(
            f'Yandex connection failed ({type(error).__name__}); '
            'check outbound TCP 587 and TLS. Server secrets were not created.'
        ) from None
    os.environ.update(SMTP_HOST='smtp.yandex.ru', SMTP_PORT='587', SMTP_USER=address,
                      SMTP_PASSWORD=password, SMTP_FROM=f'VoiceChat <{address}>')
    bootstrap.main()


if __name__ == '__main__':
    main()
