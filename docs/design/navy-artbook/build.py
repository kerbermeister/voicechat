"""VoiceChat: ten navy systems, six current screens, shared mobile/web components."""
from pathlib import Path
import ast
import html
import json

ROOT = Path(__file__).resolve().parent
# Reuse the project's established vector family, without executing an older builder.
tree = ast.parse((ROOT.parent / 'artbook-2026-10/build.py').read_text())
ICONS = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'paths' for t in n.targets))
ICONS.update({'close':'M6 6l12 12 M18 6L6 18','calendar':'M4 5h16v16H4z M4 10h16 M8 2v6 M16 2v6','monitor':'M3 4h18v13H3z M12 17v4 M7 21h10','copy':'M8 8h12v12H8z M16 8V4H4v12h4','chevron':'M9 5l7 7-7 7','smile':'M3 12a9 9 0 1 0 18 0 9 9 0 0 0-18 0 M8 9h.01 M16 9h.01 M8 14q4 5 8 0','refresh':'M20 7a9 9 0 1 0 1 9 M20 2v6h-6','volume':'M4 9h4l5-4v14l-5-4H4z M17 8q5 4 0 8','signal':'M5 20v-4 M10 20V12 M15 20V8 M20 20V4'})
# Each palette shares the same semantic contract on Android and web.
variants = [
 dict(id='haven',name='Haven',ru='Тихая гавань',tag='Мягкая классика',desc='Близко к текущей логике: тональная шапка, собранные строки и мягкая панель переписки. Синий объединяет, а не отвлекает.',layout='Плотный список + цельные панели',bg='#0c172b',surface='#14243e',raised='#203653',accent='#b5d1ff',muted='#b2c2d8',radius='22px'),
 dict(id='lumen',name='Lumen',ru='Свет над глубиной',tag='Воздушные слои',desc='Плавающая навигация, широкие поля и лёгкие световые края. Элементы управления выделены в отдельный слой над спокойным содержимым.',layout='Свободный список + плавающая панель',bg='#0b172b',surface='#1a2c46',raised='#2a4261',accent='#d1e2ff',muted='#bccbdf',radius='30px'),
 dict(id='studio',name='Studio',ru='Точность без холода',tag='Spectrum-inspired',desc='Точная иерархия, модульные группы и спокойный контраст. Хорошо работает при большом числе разговоров и в широком веб-окне.',layout='Модульная сетка + компактные группы',bg='#101a2c',surface='#19273e',raised='#293a54',accent='#a9ceff',muted='#b8c5da',radius='14px'),
 dict(id='cove',name='Cove',ru='Всё ближе',tag='Мягкие листы',desc='Содержимое собрано в крупные скруглённые листы. Шапка остаётся тёмной; действия внизу визуально продолжают основную панель.',layout='Выразительная шапка + округлый лист',bg='#0a1b32',surface='#1b3652',raised='#2a4967',accent='#b8e1ee',muted='#b8cedf',radius='32px'),
 dict(id='halo',name='Halo',ru='Голос в центре',tag='Аудио как акцент',desc='Голосовая дорожка становится главным выразительным элементом. Крупные кнопки воспроизведения и мягкое свечение помогают быстро находить аудио.',layout='Голосовая карточка + крупный медиаблок',bg='#101a35',surface='#1c2b4b',raised='#2c3d60',accent='#c3d0ff',muted='#bdc8e1',radius='26px'),
 dict(id='frost',name='Frost',ru='Синий и свет',tag='Светлые рабочие поверхности',desc='Тёмно-синяя оболочка и светлые голубоватые карточки. Переписка читается как чистый лист, сохраняя общий ночной характер приложения.',layout='Тёмная оболочка + светлые карточки',bg='#0c1c34',surface='#192e4b',raised='#284361',accent='#c1dfff',muted='#bed0e5',radius='22px'),
 dict(id='aurora',name='Aurora',ru='Сумеречный синий',tag='Деликатный градиент',desc='Синие поверхности с едва заметным лиловым переливом. Градиент сосредоточен в шапках и главных действиях, текст остаётся на спокойном фоне.',layout='Тональные островки + мягкий цвет',bg='#111b36',surface='#202d50',raised='#334267',accent='#d1d3ff',muted='#c2c9e4',radius='26px'),
 dict(id='ribbon',name='Ribbon',ru='Линия разговора',tag='Горизонтальный ритм',desc='Мягкие строки и тонкие вертикальные метки вместо множества карточек. Веб-версия сохраняет этот ритм в трёх связанных колонках.',layout='Непрерывные строки + боковые метки',bg='#0b1a2c',surface='#172b43',raised='#284058',accent='#acd7ed',muted='#b6cbdc',radius='18px'),
 dict(id='pearl',name='Pearl',ru='Перламутровая глубина',tag='Серебристый синий',desc='Светлые акценты на приглушённых синих поверхностях. Профиль и ключевые сообщения получают более светлый слой, остальная навигация отступает.',layout='Выделенный профиль + спокойные секции',bg='#142137',surface='#25364e',raised='#374b64',accent='#d8e7fb',muted='#c5d1e2',radius='28px'),
 dict(id='meridian',name='Meridian',ru='Единая точка связи',tag='Сбалансированная система',desc='Крупные смысловые группы, ясные подписи и общая нижняя панель действий. Одинаково уверенно выглядит на Android и на широком экране.',layout='Группы действий + единая нижняя панель',bg='#0d1b32',surface='#1c304b',raised='#304764',accent='#b8d6ff',muted='#becde0',radius='24px'),
]

def ic(n):
 return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{ICONS[n]}"/></svg>'
def control(n,label,action='',cls=''):
 return f'<button type="button" class="iconbtn {cls}" aria-label="{label}" title="{label}" data-action="{action or label}">{ic(n)}</button>'
def action(label,n=None,key='',cls=''):
 return f'<button type="button" class="action {cls}" data-action="{key or label}">{ic(n) if n else ""}<span>{label}</span></button>'
def av(name,size='',photo=False):
 return f'<span class="avatar {size} {"photo" if photo else ""}">'+('<img src="assets/call-portrait.png" alt="">' if photo else html.escape(name))+'</span>'
def wave():
 return '<span class="wave" aria-hidden="true">'+''.join(f'<i style="--h:{h}px"></i>' for h in [7,13,20,29,17,34,24,13,20,38,24,12,8,21,30,17,12,28,36,20,10,18,26,13])+'</span>'
def head(title,sub='',icon='back',right='more',key='Меню'):
 return f'<div class="screenhead">{control(icon,"Назад" if icon=="back" else "Профиль", "Профиль")}<div><h3>{title}</h3><small>{sub}</small></div>{control(right,key,key)}</div>'
def row(title,sub,n='settings',key='',tail=''):
 return f'<button type="button" class="setting" data-action="{key or title}"><span class="settingicon">{ic(n)}</span><span class="rowcopy"><b>{title}</b><small>{sub}</small></span>{tail or ic("chevron")}</button>'
def person(name,msg,time,initial,active=False):
 return f'<button type="button" class="person {"selected" if active else ""}" data-action="Чат"><span class="avatarwrap">{av(initial,photo=name=="Мама")}'+('<i class="online"></i>' if name=='Мама' else '')+f'</span><span class="rowcopy"><b>{name}</b><small>{msg}</small></span><span class="personmeta"><time>{time}</time>'+('<span class="badge">2</span>' if active else ic('check'))+'</span></button>'
def nav():
 return '<div class="appnav">'+action('Люди','people','Люди','current')+action('Группы','chat','Группы')+action('Настройки','settings','Настройки')+'</div>'
def conversations(v):
 return ('<div class="brandline"><span class="brandmark">'+ic('mic')+'</span><b>VoiceChat</b>'+control('mail','Приглашения · 2','Приглашения')+control('settings','Настройки','Настройки')+'</div>'+
 '<div class="listheading"><div><small>ВАШИ ЛЮДИ РЯДОМ</small><h3>Разговоры</h3></div>'+control('plus','Найти человека','Найти человека','emphasis')+'</div>'+
 '<div class="searchfield">'+ic('search')+'<span>Найти разговор</span>'+control('search','Поиск по чатам и сообщениям','Поиск')+'</div>'+
 '<div class="segmented"><button class="active" data-action="Люди">Люди <span>2</span></button><button data-action="Группы">Группы <span>3</span></button></div>'+
 '<div class="listbody"><div class="invitebar">'+ic('mail')+'<span>Приглашения</span><button data-action="Приглашения">2 новых '+ic('chevron')+'</button></div>'+
 '<div class="peoplelist">'+person('Мама','Голосовое сообщение · 0:18','14:32','М',True)+person('Аня','Давай созвонимся вечером','13:48','А')+person('Папа','Фотография','12:05','П')+person('Илья','Спасибо, до завтра!','Вчера','И')+'</div>'+action('Найти человека','plus','Найти человека','primary addperson')+'</div>'+nav())
def chat(v):
 return ('<div class="chathead">'+control('back','Назад','Люди')+av('М',photo=True)+'<div class="chatidentity"><h3>Мама</h3><small><i></i> В сети</small></div>'+control('phone','Голосовой звонок','Голосовой звонок')+control('video','Видеозвонок','Видеозвонок')+control('more','Меню чата','Меню чата')+'</div>'+
 '<div class="historybar">'+control('search','Поиск в переписке','Поиск')+'<span>Поиск в переписке</span>'+control('calendar','Перейти к дате','Календарь')+'</div>'+
 '<div class="messages"><div class="day">Сегодня, 23 октября</div><div class="bubble received">В воскресенье собираемся у нас?<span class="meta">14:30 '+control('more','Действия с сообщением','Сообщение')+'</span></div><div class="bubble sent"><div class="reply">Мама <span>В воскресенье собираемся у нас?</span></div>Конечно! Буду к пяти.<span class="meta">14:31 · прочитано '+control('more','Действия с сообщением','Моё сообщение')+'</span></div>'+
 '<div class="voicecard"><div class="voicelabel"><span>Голосовое сообщение</span><b>0:18</b></div><div class="voiceplayer">'+control('play','Воспроизвести голосовое','Голосовое','emphasis')+wave()+'</div><div class="meta">14:32 '+control('more','Действия с голосовым','Сообщение')+'</div></div>'+
 '<div class="bubble received">Тогда до встречи!<span class="meta">14:33 '+control('more','Действия с сообщением','Сообщение')+'</span></div></div>'+
 '<div class="chatfooter"><button class="queue" data-action="Расписание">'+ic('clock')+'<span>Запланировано</span><b>2</b>'+ic('chevron')+'</button><div class="toolstrip">'+control('image','Отправить изображение','Вложения')+control('file','Файл или видео','Вложения')+control('video','Записать видеокружок','Видеокружок')+control('clock','Временное сообщение','Таймер')+control('calendar','Отложить отправку','Расписание')+control('smile','Эмодзи','Эмодзи')+'</div><div class="composer">'+control('plus','Дополнительные действия','Инструменты')+'<span>Сообщение…</span>'+control('mic','Записать голосовое','Запись')+control('send','Отправить сообщение','Отправка','emphasis')+'</div></div>')
def group(v):
 return (head('Семья','Участники и настройки',key='Меню группы')+'<div class="groupintro">'+av('С','big')+'<div><h3>Все свои.</h3><p>Семья · 4 участника</p></div>'+control('more','Изменить группу','Меню группы')+'</div><div class="segmented"><button class="active" data-action="Участники">Вступили · 4</button><button data-action="Приглашённые">Приглашены · 1</button></div><div class="memberlist">'+row('Антон','Это вы · администратор','people','Профиль')+row('Мама','В сети','people','Участник')+row('Аня','Была недавно','people','Участник')+row('Папа','Был сегодня','people','Участник')+'</div><div class="groupfooter">'+action('Пригласить человека','plus','Пригласить','primary')+'<div class="pairactions">'+action('Аватар','image','Аватар')+action('Название','file','Название')+'</div>'+action('Покинуть группу','arrow','Выход из группы','danger')+'</div>')
def video(v):
 return (head('Видеозвонок','Мама · 04:32',icon='back',right='more',key='Меню звонка')+'<div class="videoarea"><img class="videoportrait" src="assets/call-portrait.png" alt="Вымышленная собеседница — иллюстрация видеозвонка"><span class="quality">'+ic('signal')+' Хорошая связь</span><div class="selfvideo">'+av('А')+'<span>Вы · камера выкл.</span></div><div class="videoname"><b>Мама</b><span>На связи</span></div></div><div class="callbottom"><div class="callcontrols">'+action('Микрофон','mic','Микрофон')+action('Камера','video','Камера')+action('Аудио','speaker','Аудиовыход')+'</div><div class="calloptions">'+action('Сменить камеру','refresh','Сменить камеру')+action('Качество','signal','Качество видео')+'</div><div class="screenoption">'+action('Демонстрация экрана','monitor','Демонстрация экрана')+'<small>Экспериментально · при доступности</small></div>'+action('Завершить','phone','Завершить звонок','hangup')+'</div>')
def settings(v):
 return (head('Настройки','Аккаунт и приложение')+'<button class="profilecard" data-action="Профиль">'+av('А','big')+'<span><h3>Антон</h3><small>@anton:example.org</small><span class="profileedit">Профиль и аватар '+ic('chevron')+'</span></span></button><div class="settingsgroup"><small class="sectiontitle">ПРИЛОЖЕНИЕ</small>'+row('Кто может писать','Только после подтверждения','people','Приватность')+row('Оформление и звуки',v['name']+' · звуки включены','settings','Оформление')+row('Локальное хранилище','328 из 1024 МиБ','file','Хранилище')+'</div><div class="settingsgroup"><small class="sectiontitle">БЕЗОПАСНОСТЬ И ИСТОРИЯ</small>'+row('Устройства','Сеансы, проверка и отзыв доступа','device','Устройства')+row('Ключи и восстановление','Создать ключ · восстановить · backup','lock','Восстановление')+row('Запросы истории','1 запрос ожидает ответа','clock','Запросы истории')+'</div><div class="settingsfoot">'+action('Заблокировать','lock','Блокировка')+action('Выйти','arrow','Выход','danger')+'</div>')
def devices(v):
 return (head('Устройства','Доступ к вашему аккаунту')+'<div class="securityhero"><span>'+ic('shield')+'</span><div><h3>Ваш круг доверия</h3><small>2 устройства · 1 требует проверки</small></div></div><div class="devicecard"><div class="devicetop">'+ic('device')+'<div><h4>Этот Android</h4><small>Текущее устройство</small></div></div><div class="trusted">'+ic('check')+' Проверено</div><div class="idrow"><code>ANDROID01</code>'+control('copy','Копировать ID устройства','Копирование')+'</div></div><div class="devicecard"><div class="devicetop">'+ic('monitor')+'<div><h4>Браузер на ноутбуке</h4><small>Личность не подтверждена</small></div></div><div class="idrow"><code>WEB02</code>'+control('copy','Копировать ID устройства','Копирование')+'</div>'+action('Проверить устройство','shield','Проверка','primary')+action('Отозвать доступ',None,'Отзыв доступа','danger')+'</div><button class="verificationmethods" data-action="Проверка">QR-код · Коды · Полный отпечаток '+ic('chevron')+'</button><p class="securitynote">Отзыв завершает сеанс. Ранее скачанные копии нельзя удалить удалённо.</p>')
SCREENS=[('Разговоры',conversations,'05-people'),('Личный чат',chat,'18-chat'),('Группа',group,'19-members'),('Видеозвонок',video,'32-call-video-fixture'),('Настройки',settings,'10-settings'),('Устройства',devices,'13-devices')]

def tokens(v):
 return ';'.join('--'+k+':'+v[k] for k in ['bg','surface','raised','accent','muted','radius'])
def frame(v,i):
 title,render,source=SCREENS[i]
 return f'<figure class="screenfigure" data-screen="{i}"><div class="phone screen-{i}"><div class="statusbar"><span>9:41</span><span>{ic("signal")} 87%</span></div><div class="screen">{render(v)}</div><div class="homeindicator"></div></div><figcaption><b>0{i+1}</b> {title}<a href="../mobile-refresh/after/web/{source}.png" target="_blank" rel="noopener">Оригинал ↗</a></figcaption></figure>'

def desktop(v):
 return '<div class="desktop"><div class="windowtitle"><span class="windowdots">● ● ●</span> VoiceChat <span>Web · '+v['name']+'</span></div><div class="desktopgrid"><aside class="desktoprail">'+ic('mic')+control('people','Люди','Люди')+control('chat','Группы','Группы')+control('settings','Настройки','Настройки')+'</aside><div class="desktoplist">'+conversations(v)+'</div><div class="desktopchat">'+chat(v)+'</div><aside class="desktopdetail"><div class="detailprofile">'+av('М','big',True)+'<h3>Мама</h3><small>В сети</small></div>'+action('Голосовой звонок','phone','Голосовой звонок')+action('Видеозвонок','video','Видеозвонок')+row('Поиск','По загруженной истории','search','Поиск')+row('Запланировано','2 сообщения','clock','Расписание')+row('Профиль','Информация о собеседнике','people','Профиль')+'</aside></div></div>'

# These secondary-route notes are available from controls, without pretending to call APIs.
DETAILS={
'Приглашения':['Входящие: принять или отклонить','Исходящие: отменить запрос','Люди и приглашения в группы'],
'Найти человека':['Поиск по имени или @username:server','Результаты → профиль → начать разговор','Нет результатов / ошибка → повторить поиск'],
'Люди':['Список людей','Поиск по имени','Приглашения и профиль'],
'Группы':['Список групп','Создать группу: название → выбрать участников','Принять или отклонить приглашение'],
'Поиск':['Поиск по загруженной истории','Перейти к найденному сообщению','Результаты могут быть неполными: ранняя история и ключи загружаются отдельно'],
'Календарь':['Выбрать дату','Перейти к дате в истории','Вернуться к новым сообщениям'],
'Меню чата':['Профиль собеседника / участники группы','Поиск и календарь','Запросить недоступные ключи истории','Загрузить более ранние сообщения'],
'Сообщение':['Ответить','Реакция…','Открыть вложение при наличии'],
'Моё сообщение':['Ответить','Редактировать','Удалить у всех → подтверждение','Реакция…'],
'Голосовое':['Воспроизвести / приостановить','Дорожка, длительность и состояние воспроизведения'],
'Запись':['Запись → остановить','Прослушать готовую запись','Удалить черновик или отправить'],
'Вложения':['Изображение / альбом','Видеофайл','Файл','Предпросмотр → удалить из черновика или отправить','Существующие лимиты размера и ошибки сохраняются'],
'Видеокружок':['Записать видеосообщение','Остановить и просмотреть','Удалить или отправить'],
'Таймер':['Выбрать срок временного сообщения в пределах серверной политики','Без таймера','Применить'],
'Расписание':['Выбрать дату и время отправки','Очередь: 2 запланированных сообщения','Изменить время / повторить при ошибке / отменить'],
'Инструменты':['Фото, файл, видео, видеокружок','Голосовое сообщение и эмодзи','Временное сообщение и расписание'],
'Эмодзи':['Панель эмодзи','Выбранный символ добавляется в черновик'],
'Участник':['Открыть профиль','Исключить участника при наличии прав → подтверждение'],
'Приглашённые':['Список приглашённых','Профиль приглашённого','Отменить приглашение при наличии прав'],
'Меню группы':['Изменить аватар','Изменить название','Пригласить участника','Покинуть группу → подтверждение'],
'Выход из группы':['Подтвердить выход из группы','Отмена возвращает в группу'],
'Приватность':['Мне могут писать без подтверждения: включить / выключить','Состояние сохраняется только после успешного ответа сервера','Ошибка сохраняет предыдущий выбор'],
'Оформление':['Цветовая схема','Звуки сообщений и вызовов','Если браузер блокирует звук — показать причину'],
'Хранилище':['Занято 328 МиБ из лимита 1024 МиБ','Изменить лимит локальной копии','Проверить / очистить старую локальную историю','Это не свободное место на диске; скачанные файлы учитываются отдельно'],
'Восстановление':['Создать ключ восстановления → сохранить отдельно','Восстановить историю по ключу','Обновить backup','Запросить историю у своего устройства'],
'Запросы истории':['Список запросов и статусы','Подтвердить или отклонить передачу истории'],
'Проверка':['QR-код: показать / сканировать','Сравнить коды','Сверить полный отпечаток','Аккаунт, устройство и отпечаток можно копировать','Продолжить входящую проверку / отменить'],
'Отзыв доступа':['Подтвердить паролем аккаунта','Отозвать серверный сеанс','Ранее сохранённые копии удалённо не стираются'],
'Выход':['Выйти и удалить локальные ключи?','Подтверждение или отмена','Ключ восстановления нужен для последующего доступа к истории'],
'Блокировка':['Web: закрыть локальные ключи в этой вкладке','Разблокировка отдельной локальной фразой'],
'Профиль':['Имя, ID аккаунта и статус','Мой профиль → изменить аватар','Чужой профиль → состояние приглашения'],
'Меню звонка':['Свернуть / открыть звонок','Голосовой и видеорежим','Для группы — участники и видеосетка','Входящий: принять / отклонить; ошибка: причина и закрыть'],
'Качество видео':['Выбор качества видео','Индикация качества сети','Восстановление соединения и ошибка'],
'Демонстрация экрана':['Экспериментальная capability по умолчанию выключена','При доступности: показать / перехватить / остановить','Auto / Low и полноэкранный просмотр','Mobile web — только просмотр'],
'Микрофон':['Включить / выключить микрофон','Состояние и разрешение устройства'],
'Камера':['Включить / выключить камеру','Состояние и разрешение устройства'],
'Аудиовыход':['Выбор доступного аудиовыхода'],
'Сменить камеру':['Переключить доступную камеру'],
'Завершить звонок':['Завершение активного вызова','Возврат в переписку'],
'Голосовой звонок':['Голосовой вызов → состояние соединения','Таймер, качество, микрофон, аудиовыход и завершение'],
'Видеозвонок':['Видеовызов → соединение','Управление камерой, микрофоном и качеством'],
'Настройки':['Профиль, приватность, оформление, звуки, хранилище','Устройства, ключи, история, блокировка и выход'],
'Устройства':['Список устройств и отзыв доступа','Проверка QR / кодами / отпечатком'],
'Копирование':['В рабочем приложении копирует полный идентификатор в буфер обмена'],
'Чат':['Открыть выбранную переписку','Контекстное меню чата → информация'],
'Отправка':['Отправка черновика','Локальная очередь, повтор и ошибка сохраняются'],
'Участники':['Вступившие участники','Профили и действия в соответствии с правами'],
'Пригласить':['Выбрать человека','Приглашённый появляется в отдельной вкладке'],
'Аватар':['Выбрать изображение','Редактирование и сохранение аватара'],
'Название':['Изменить название при наличии прав','Сохранить или отменить'],
'Меню':['Контекстные действия текущего экрана'],
}

css=(ROOT/'styles.css').read_text()
body='''<header class="cover"><div class="covereyebrow">VOICECHAT / NAVY COLLECTION / 2026</div><div class="covertitle"><h1>Ближе.<br><em>В оттенках синего.</em></h1><div class="coveraside"><span>10 × 6</span><p>Десять направлений.<br>Один дизайн-код.<br>Android + Web.</p></div></div><p class="coverintro">Мягкость Apple. Ясность Spectrum.<br>Знакомый VoiceChat — с новым ощущением глубины.</p><div class="coverline"><span>60 основных экранов</span><span>10 широких веб-компоновок</span><span>Демонстрационные данные</span></div></header>
<nav class="booknav" aria-label="Управление артбуком"><a href="#overview" class="booklogo">VC / Navy</a><label>Направление<select id="direction"><option value="overview">Обзор</option>'''+''.join(f'<option value="{v["id"]}">{i+1:02} · {v["name"]}</option>' for i,v in enumerate(variants))+'''</select></label><label>Сравнить экран<select id="screenfilter"><option value="all">Все шесть</option>'''+''.join(f'<option value="{i}">{s[0]}</option>' for i,s in enumerate(SCREENS))+'''</select></label><label>Поверхность<select id="surface"><option value="mobile">Android / мобильный web</option><option value="web">Широкий web</option></select></label><a href="#contract">Карта функций</a><button id="print">Печать</button></nav>
<section class="overview" id="overview"><div class="eyebrow">НОВАЯ СЕРИЯ / ЕДИНАЯ ВИЗУАЛЬНАЯ СЕМЬЯ</div><h2>Различаются компоновки.<br>Сохраняется характер.</h2><p class="introcopy">Тёмно-синий фон, более светлые поверхности, спокойный текст и лёгкие градиенты. Все варианты используют одну структуру функций. Кнопки открывают пояснение соответствующего сценария; они не отправляют сообщения и не запускают вызовы.</p><div class="conceptgrid">'''
for i,v in enumerate(variants):
 body+=f'<a class="conceptcard {v["id"]}" style="{tokens(v)}" href="#{v["id"]}"><span class="conceptnumber">{i+1:02}</span><div class="minipalette"><i></i><i></i><i></i></div><h3>{v["name"]}</h3><span>{v["tag"]}</span><small>{v["layout"]}</small></a>'
body+='</div></section>'
for i,v in enumerate(variants):
 body+=f'<section class="chapter {v["id"]}" id="{v["id"]}" style="{tokens(v)}"><header class="chapterhead"><div><div class="eyebrow">{i+1:02} / {v["tag"]}</div><h2>{v["name"]}<span>{v["ru"]}</span></h2></div><div><p>{v["desc"]}</p><div class="paletterow">'+''.join(f'<span style="background:{v[k]}" title="{v[k]}"></span>' for k in ['bg','surface','raised','accent'])+f'<small>{v["layout"]}</small></div></div></header><div class="mobilespread">'+''.join(frame(v,j) for j in range(6))+'</div><div class="webspread" hidden>'+desktop(v)+'</div><footer class="chapterfoot"><span>Один набор цветов, компонентов и состояний для Android и веба.</span><a href="#contract">Функции и вторичные сценарии ↗</a></footer></section>'
body+='''<section class="contract" id="contract"><div class="eyebrow">ФУНКЦИОНАЛЬНЫЙ КОНТРАКТ</div><h2>Функции остаются.<br>Меняется их подача.</h2><p>Основой служат текущие conversation_list.dart, chat_pane.dart, room_members_dialog.dart, call_window.dart и настройки main.dart. Ниже — маршруты, общие для всех десяти направлений.</p><div class="contractgrid">'''
for title,keys in [('01 / Разговоры',['Люди','Группы','Приглашения','Найти человека','Поиск']),('02 / Переписка',['Моё сообщение','Запись','Вложения','Видеокружок','Расписание','Таймер','Календарь']),('03 / Группа',['Меню группы','Участник','Приглашённые']),('04 / Звонки',['Меню звонка','Качество видео','Демонстрация экрана']),('05 / Настройки',['Приватность','Оформление','Хранилище','Восстановление','Запросы истории','Выход','Блокировка']),('06 / Устройства',['Проверка','Отзыв доступа'])]:
 body+=f'<article><h3>{title}</h3>'+''.join(f'<details><summary>{key}</summary><ul>'+''.join(f'<li>{html.escape(t)}</li>' for t in DETAILS[key])+'</ul></details>' for key in keys)+'</article>'
body+='''</div><details class="additional"><summary>Вход, дополнительные состояния и ограничения</summary><p>До списка разговоров сохраняются вход, регистрация с подтверждением почты, сброс пароля, параметры подключения и выбор профиля. В вебе — отдельная локальная фраза и сохранение входа. Просмотр фото и альбомов, ссылки, видео, редактор аватара, разрешения, пустые списки, офлайн, ошибки отправки, загрузка истории и ключей остаются вторичными маршрутами.</p><p>Шесть экранов — визуальные макеты основных сценариев, не полная отрисовка всех состояний. Реальные звонки, E2EE и работа на оборудовании здесь не проверяются. Состояния связи и проверки устройств демонстрационные. Экспериментальная демонстрация экрана не становится включённой от изменения дизайна.</p></details><div class="sourceprinciples"><h3>Принципы, а не копия платформы</h3><p>Из <a href="https://spectrum.adobe.com/page/color-system/">Adobe Spectrum</a> взяты смысловые роли цвета и иерархия поверхностей. Из <a href="https://developer.apple.com/design/human-interface-guidelines/materials">Apple HIG</a> — разделение содержимого и слоя управления, сдержанное использование материалов. Это авторская система VoiceChat, а не реализация официальных компонентов Adobe или Apple.</p><p>Шрифт — системный гротеск с кириллицей. Сетка 4/8, общие токены радиусов, светлые акценты на тёмных поверхностях. В рабочем Flutter-клиенте сохраняются TextScaler, доступные подписи и уменьшение движения. На Android и вебе меняется компоновка, а не визуальный язык.</p><p><a href="../mobile-refresh/index.html">Текущая галерея приложения ↗</a> · <a href="README.md">Исходники и проверка ↗</a></p></div></section><footer class="bookend"><span>VOICECHAT / NAVY COLLECTION</span><p>Выбрать ощущение. Затем довести систему.</p><small>Статический артбук · 23 октября 2026 · Код приложения не изменён.</small></footer>
<dialog id="detail"><div class="dialoghead"><div><small>МАРШРУТ В РАБОЧЕМ ПРИЛОЖЕНИИ</small><h2 id="dialogtitle"></h2></div><button id="close-dialog" aria-label="Закрыть">×</button></div><ul id="dialogbody"></ul><p>В артбуке показан сценарий. Данные аккаунта и медиа не подключены.</p></dialog>'''
script='const routeDetails='+json.dumps(DETAILS,ensure_ascii=False)+';\n'+(ROOT/'book.js').read_text()
assert len(variants)==10 and len(SCREENS)==6
assert body.count('class="screenfigure"')==60
(ROOT/'index.html').write_text('<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VoiceChat · Navy Collection · 10 × 6</title><style>'+css+'</style></head><body>'+body+'<script>'+script+'</script></body></html>')
(ROOT/'tokens.json').write_text(json.dumps(variants,ensure_ascii=False,indent=2))
print('Built 60 mobile screens and 10 desktop compositions')
# Portable contact sheet: the same chat in all ten systems, without external assets.
overview='<header class="atlashead"><small>VOICECHAT / NAVY COLLECTION</small><h1>Один разговор. Десять ощущений.</h1><p>Мягкий тёмно-синий интерфейс · одинаковый функционал · полный артбук: 10 × 6 экранов</p></header><main class="atlasgrid">'
for i,v in enumerate(variants):
 overview+=f'<section class="atlasitem {v["id"]}" style="{tokens(v)}"><h2><small>{i+1:02}</small> {v["name"]}</h2>'+frame(v,1)+'</section>'
overview+='</main>'
atlascss='''body{padding:35px;background:#081325}.atlashead{padding:10px 10px 35px}.atlashead>small{font-size:12px;letter-spacing:3px;color:#a7c6ef}.atlashead h1{font-size:52px;font-weight:500;letter-spacing:-2px;margin:20px 0}.atlashead p{font-size:17px;color:#bbcee7}.atlasgrid{display:grid;grid-template-columns:repeat(5,390px);gap:30px}.atlasitem{--ink:#f1f5ff;--line:#abc9f222;--on-accent:#12233c}.atlasitem h2{font-size:27px;letter-spacing:-.7px;margin:0 0 18px;font-weight:500}.atlasitem h2 small{font-size:12px;color:var(--muted);margin-right:8px}.atlasitem figcaption{display:none}.atlasitem .phone{height:930px}.atlasitem .screenfigure{margin:0}'''
(ROOT/'overview.html').write_text('<!doctype html><html lang="ru"><meta charset="utf-8"><title>VoiceChat · Обзор 10 направлений</title><style>'+css+atlascss+'</style>'+overview+'</html>')
