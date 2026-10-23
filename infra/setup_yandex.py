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
    if '@' not in address or any(c.isspace() for c in address):
        raise SystemExit('Enter the full Yandex email address')
    password = getpass.getpass('Yandex app password (hidden): ')
    if not password:
        raise SystemExit('An app password is required')
    try:
        with smtplib.SMTP('smtp.yandex.ru', 587, timeout=20) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(address, password)
    except (OSError, smtplib.SMTPException):
        raise SystemExit('Yandex connection/authentication failed; check app password and outbound TCP 587') from None
    os.environ.update(SMTP_HOST='smtp.yandex.ru', SMTP_PORT='587', SMTP_USER=address,
                      SMTP_PASSWORD=password, SMTP_FROM=f'VoiceChat <{address}>')
    bootstrap.main()


if __name__ == '__main__':
    main()
