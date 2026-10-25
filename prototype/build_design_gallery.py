"""Package matching, local screenshots. No credentials or app bundles enter docs."""
import html
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'docs/design/mobile-refresh'
SCREENS = {
    '01-welcome': 'Вход',
    '02-registration': 'Регистрация',
    '03-reset-password': 'Восстановление пароля',
    '04-connection': 'Параметры подключения',
    '05-people': 'Люди · пустой список',
    '06-find-person': 'Поиск собеседника',
    '07-invitations': 'Приглашения',
    '08-history-search': 'Поиск по переписке',
    '09-profile': 'Мой профиль',
    '10-settings': 'Настройки',
    '11-settings-security': 'Настройки · безопасность и история',
    '12-storage': 'Локальное хранилище',
    '13-devices': 'Устройства аккаунта',
    '14-verification': 'Проверка устройств',
    '15-history-requests': 'Запросы истории',
    '16-groups': 'Список групп',
    '17-new-group': 'Создание группы',
    '18-chat': 'Переписка · текст и голосовое',
    '19-members': 'Участники группы',
    '20-members-invited': 'Приглашённые участники',
    '21-message-menu': 'Действия с сообщением',
    '22-reply': 'Ответ на сообщение',
    '23-emoji': 'Эмодзи',
    '24-temporary': 'Временное сообщение',
    '25-scheduled': 'Запланированные сообщения',
    '26-schedule-time': 'Выбор времени отправки',
    '27-calendar': 'Календарь истории',
    '28-composer-tools': 'Панель вложений и дополнительных действий',
    '29-attachment-menu': 'Выбор типа вложения',
    '30-edit-message': 'Редактирование сообщения',
    '31-delete-confirmation': 'Подтверждение удаления',
    '32-call-incoming-fixture': 'Входящий звонок · UI fixture',
    '32-call-voice-fixture': 'Голосовой звонок · UI fixture',
    '32-call-video-fixture': 'Видеозвонок · UI fixture',
    '32-call-error-fixture': 'Ошибка звонка · UI fixture',
}


def main():
    sections = []
    for platform in ['android', 'web']:
        for key, title in SCREENS.items():
            cards = []
            for version, label in [('before', 'До'), ('after', 'После')]:
                source = ROOT / f'.prototype/design-{version}-{platform}{"-shots" if platform == "web" else ""}/{key}.png'
                target = DESTINATION / version / platform / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_file():
                    if version == 'after' and target.is_file():
                        approved = DESTINATION / 'approved' / platform / source.name
                        approved.parent.mkdir(parents=True, exist_ok=True)
                        if not approved.is_file():
                            shutil.copy2(target, approved)
                    shutil.copy2(source, target)
                elif version != 'before' or not target.is_file():
                    raise SystemExit(f'Missing screenshot: {source.relative_to(ROOT)}')
                url = target.relative_to(DESTINATION).as_posix()
                cards.append(f'<figure><figcaption>{label}</figcaption><a href="{url}" target="_blank"><img loading="lazy" src="{url}" alt="{html.escape(title)} — {label}"></a></figure>')
            sections.append(f'<section data-platform="{platform}" data-key="{key}" id="{platform}-{key}"><h2>{html.escape(title)}</h2><div class="pair">{"".join(cards)}</div></section>')
    options = ''.join(f'<option value="{key}">{html.escape(title)}</option>' for key, title in SCREENS.items())
    content = '''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VoiceChat · Lavender Soft · до / после</title>
<style>*{box-sizing:border-box}body{margin:0;background:#faf8fd;color:#312940;font:16px/1.5 system-ui,sans-serif}header,main{max-width:1000px;margin:auto;padding:24px}header{padding-bottom:12px}h1{font-size:clamp(24px,4vw,36px);letter-spacing:-1px;margin:0}p{color:#736a81}nav{position:sticky;top:0;z-index:1;background:#faf8fdf5;backdrop-filter:blur(12px);padding:16px 24px;display:flex;gap:12px;flex-wrap:wrap;justify-content:center;border-bottom:1px solid #eae3f3}select{font:inherit;color:#312940;background:white;border:1px solid #eae3f3;border-radius:14px;padding:12px;min-height:48px;max-width:100%}section{margin:0 0 48px;scroll-margin-top:100px}h2{font-size:20px}figure{margin:0;min-width:0}figcaption{font-weight:650;padding:12px 4px}figure:last-child figcaption{color:#8055d7}img{display:block;width:100%;height:auto;border-radius:22px;border:1px solid #eae3f3;background:white;box-shadow:0 12px 28px #39215412}.pair{display:grid;grid-template-columns:1fr 1fr;gap:20px;max-width:800px}a:focus-visible,select:focus-visible{outline:3px solid #8055d7;outline-offset:4px}[hidden]{display:none!important}.note{padding:16px 20px;background:#efe8fb;border-radius:18px}footer{max-width:1000px;margin:auto;padding:24px;color:#736a81}@media(max-width:480px){header,main{padding:16px}.pair{gap:10px}nav{padding:12px}h2{font-size:17px}img{border-radius:12px}figcaption{font-size:14px}}</style>
<header><h1>VoiceChat · Lavender Soft</h1><p>Реальные снимки интерфейса до и после изменений · 22–23 октября 2026</p><p class="note">Android — эмулятор API 35. Мобильный сайт — Chrome, 390 × 844 px. Сообщения и голосовое — тестовые данные. Окна звонков помечены как UI fixtures: состояния заданы тестом, камера, микрофон и медиасоединение не запускаются.</p><p><a href="queue-update/index.html">Дополнение: видимая очередь расписания и основной сайт</a> · <a href="http://localhost:7357/">Открыть сайт</a></p><p><a href="voice-update/index.html">Новое: голосовые, ровные отступы и лёгкие переходы</a></p></header>
<nav aria-label="Выбор сравнения"><select id="platform" aria-label="Платформа"><option value="android">Приложение Android</option><option value="web">Мобильный сайт</option></select><select id="screen" aria-label="Экран"><option value="all">Все экраны (35)</option>OPTIONS</select></nav><main>SECTIONS</main>
<footer>Снимки используют одноразовые тестовые аккаунты. Системная клавиатура, системные окна выбора файлов и активный захват камеры/микрофона в этот обзор не входят. Для увеличения откройте снимок.</footer>
<script>const platform=document.querySelector('#platform'),screen=document.querySelector('#screen'),params=new URLSearchParams(location.search);for(const select of [platform,screen]){const value=params.get(select.id);if([...select.options].some(o=>o.value===value))select.value=value;}function update(){document.querySelectorAll('section').forEach(s=>s.hidden=s.dataset.platform!==platform.value||(screen.value!=='all'&&s.dataset.key!==screen.value));}platform.onchange=update;screen.onchange=update;update();</script></html>'''.replace('OPTIONS', options).replace('SECTIONS', ''.join(sections))
    (DESTINATION / 'index.html').write_text(content)
    (DESTINATION / 'original.html').write_text(content)
    if all((DESTINATION / 'approved' / platform / f'{key}.png').is_file()
           for platform in ['android', 'web'] for key in SCREENS):
        refined = content.replace('src="before/', 'src="approved/').replace('href="before/', 'href="approved/')
        refined = refined.replace('<figcaption>До</figcaption>', '<figcaption>Было · одобренный вариант</figcaption>')
        refined = refined.replace('<figcaption>После</figcaption>', '<figcaption>Стало · доработки</figcaption>')
        refined = refined.replace('Реальные снимки интерфейса до и после изменений · 22–23 октября 2026',
                                  'Одобренный дизайн и доработки по вашим замечаниям · 23 октября 2026')
        (DESTINATION / 'refinements.html').write_text(refined)
        (DESTINATION / 'index.html').write_text(refined)
    overview = '''<!doctype html><html lang="ru"><meta charset="utf-8"><title>VoiceChat · до / после</title><style>*{box-sizing:border-box}body{margin:0;padding:28px 36px;background:#faf8fd;color:#312940;font:16px system-ui,sans-serif}h1{font-size:28px;letter-spacing:-.8px;margin:0 0 8px}p{color:#736a81;margin:0 0 24px}main{display:grid;grid-template-columns:1fr 1fr;gap:32px}h2{font-size:18px;margin:0 0 12px}.pair{display:grid;grid-template-columns:1fr 1fr;gap:14px}span{display:block;margin-bottom:8px;color:#736a81;font-size:14px}.after{color:#8055d7;font-weight:700}img{width:100%;border:1px solid #eae3f3;border-radius:18px;box-shadow:0 8px 22px #39215410}</style><h1>VoiceChat · Lavender Soft</h1><p>Переписка до и после · все 35 экранов и состояний — в галерее</p><main>PAIRS</main></html>'''
    pairs = []
    for platform, title in [('android', 'Приложение Android · эмулятор'), ('web', 'Мобильный сайт · Chrome')]:
        cards = ''.join(f'<div><span class="{version}">{label}</span><img src="{"approved" if version == "before" and (DESTINATION / "approved").exists() else version}/{platform}/18-chat.png" alt="{title} — {label}"></div>' for version, label in [('before', 'До'), ('after', 'После')])
        pairs.append(f'<section><h2>{title}</h2><div class="pair">{cards}</div></section>')
    (DESTINATION / 'overview.html').write_text(overview.replace('PAIRS', ''.join(pairs)))
    print(f'Gallery: {len(SCREENS)} pairs × 2 platforms')


if __name__ == '__main__':
    main()
