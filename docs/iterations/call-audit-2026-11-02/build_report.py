"""Rebuild with the bundled document runtime; the registry remains authoritative."""
from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.enum.text import WD_ALIGN_PARAGRAPH
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
d=Document(); sec=d.sections[0]
sec.page_width=Inches(8.5);sec.page_height=Inches(11)
sec.top_margin=Inches(.65);sec.bottom_margin=Inches(.65)
sec.left_margin=Inches(.7);sec.right_margin=Inches(.7)
sec.header_distance=Inches(.25);sec.footer_distance=Inches(.25)
normal=d.styles['Normal'];normal.font.name='Arial';normal.font.size=Pt(10.5)
normal.paragraph_format.space_after=Pt(7);normal.paragraph_format.line_spacing=1.1
for name,size in [('Title',25),('Heading 1',18),('Heading 2',12)]:
    st=d.styles[name];st.font.name='Arial';st.font.size=Pt(size);st.font.color.rgb=RGBColor(0,0,0)
    st.paragraph_format.space_before=Pt(10);st.paragraph_format.space_after=Pt(8)
    if name!='Title':st.font.bold=True
for st in [d.styles['Normal'],d.styles['Title'],d.styles['Heading 1'],d.styles['Heading 2']]:
    pp=st.element.find(qn('w:pPr'))
    if pp is not None:
        for border in list(pp.findall(qn('w:pBdr'))):pp.remove(border)
header=sec.header.paragraphs[0];header.text='VOICECHAT   /   АУДИТ ПРИЛОЖЕНИЯ   /   02 НОЯБРЯ 2026'
header.runs[0].font.size=Pt(8);header.runs[0].font.color.rgb=RGBColor.from_string('666666')
foot=sec.footer.paragraphs[0];foot.alignment=WD_ALIGN_PARAGRAPH.RIGHT
foot.add_run('Технический отчёт   •   ')
for fld in ['PAGE','NUMPAGES']:
    if fld=='NUMPAGES':foot.add_run(' / ')
    x=OxmlElement('w:fldSimple');x.set(qn('w:instr'),fld);foot._p.append(x)
for run in foot.runs:run.font.size=Pt(8)
def p(text,style=None):return d.add_paragraph(text,style)
def h(text):d.add_heading(text,1)
def sub(text):d.add_heading(text,2)
def page(title):d.add_page_break();h(title)
def table(head,rows,widths=None):
    t=d.add_table(rows=1, cols=len(head));t.autofit=False
    if widths:
        for col,width in zip(t.columns,widths):col.width=Inches(width)
    for c,txt in zip(t.rows[0].cells,head):c.text=txt
    for row in rows:
        for c,txt in zip(t.add_row().cells,row):c.text=str(txt)
    for i,row in enumerate(t.rows):
        trpr=row._tr.get_or_add_trPr();trpr.append(OxmlElement('w:cantSplit'))
        if i==0:trpr.append(OxmlElement('w:tblHeader'))
        for c in row.cells:
            tcpr=c._tc.get_or_add_tcPr(); margins=OxmlElement('w:tcMar')
            for side in ['top','left','bottom','right']:
                x=OxmlElement('w:'+side);x.set(qn('w:w'),'85');x.set(qn('w:type'),'dxa');margins.append(x)
            tcpr.append(margins)
            shade=OxmlElement('w:shd');shade.set(qn('w:fill'),'E8EEF5' if i==0 else 'FFFFFF');tcpr.append(shade)
            borders=OxmlElement('w:tcBorders')
            for side in ['top','left','bottom','right']:
                x=OxmlElement('w:'+side);x.set(qn('w:val'),'single');x.set(qn('w:sz'),'4');x.set(qn('w:color'),'D2D8DF');borders.append(x)
            tcpr.append(borders)
            for para in c.paragraphs:
                para.paragraph_format.space_after=Pt(2);para.paragraph_format.line_spacing=1.0
                for run in para.runs:run.font.size=Pt(9.5);run.bold=(i==0)
    d.add_paragraph().paragraph_format.space_after=Pt(0)
    return t
def link(label,path):
    para=d.add_paragraph();el=OxmlElement('w:hyperlink')
    rel=d.part.relate_to(path.as_uri(),'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink',is_external=True)
    el.set(qn('r:id'),rel);r=OxmlElement('w:r');pr=OxmlElement('w:rPr');color=OxmlElement('w:color');color.set(qn('w:val'),'214F78');pr.append(color);r.append(pr)
    txt=OxmlElement('w:t');txt.text=label;r.append(txt);el.append(r);para._p.append(el)

p('Аудит VoiceChat и проверка звонков','Title')
p('Результаты 1 и 2 ноября 2026 года')
p('Подготовлено Codex для владельца проекта VoiceChat. Отчёт объединяет предыдущий широкий аудит и новый этап по личным и групповым аудио и видеозвонкам. Полные шаги и статусы каждого сценария находятся в едином реестре приёмки.')
sub('Главный результат')
p('Карта расширена с 451 до 546 подслучаев. В 11 областях звонков теперь 170 сценариев, включая 95 новых. На втором этапе воспроизведены три дополнительные группы дефектов; вместе с предыдущим аудитом добавлено 11 групп. Исправления продукта в этом задании не вносились.')
table(['Состояние карты после двух этапов','Количество'],[
('Успешно проверены в указанном объёме','46'),('Подслучаи с воспроизведёнными дефектами','14  —  11 групп'),('Наблюдения для отдельного исследования','2'),('Сохранённые прежние подтверждения пользователя','3'),('Открыты или требуют внешних условий','481'),('Всего устойчивых подслучаев','546')],[5.5,1.6])
sub('Что проверено на втором этапе')
p('Прошли 73 существующих Flutter-теста по звонкам, 11 серверных тестов, пять новых серверных проб, одна новая проба из 24 перестановок поздних событий и четыре нативных интеграционных прогона на Mac. Пять намеренно строгих assertions выявили три группы дефектов. Зелёные тесты не закрывают полные пути на телефонах.')
sub('Без взаимодействия с реальными пользователями')
p('Использовались отдельные QA-профили предыдущего этапа, синтетическая сигнализация и одна изолированная комната локального SFU. Звонки реальным контактам не выполнялись. Основное установленное приложение, его профиль и Keychain не изменялись. Продуктовый код и production остались без изменений; выпуск клиента для документации не требуется.')
p('Основа проверки: source e35dd306ff65855b2cdaa31fc87189bb5b889eb0; клиент 1.16.5 build 44; macOS 15.3.1 arm64; Flutter 3.47.7.')

page('Предыдущий широкий аудит')
p('Первый этап изучил существующие экраны и клиентские пути, добавил карту из 451 сценария для 82 UA и выполнил доступные автоматические и web UI проверки. Статусы этого этапа сохранены, а новые условия добавлены к прежним устойчивым ID.')
table(['Проверка 1 ноября','Фактический результат'],[
('Flutter и анализ','511 PASS, 4 opt-in пропуска; analyzer без замечаний'),('Python и JavaScript','786 Python PASS, 3 opt-in пропуска; 9 JavaScript VM PASS'),('Новые пробы','19 позитивных assertions и 2 проверки состояния серверных звонков; 1000 переходов и 12 одновременных допусков'),('Обычный web клиент','2 отдельных QA-аккаунта, у Alice 2 устройства; encrypted text/photo, правка, SAS, reload/restore, revoke, TTL'),('Сценарии с отдельным свидетельством','19 UI PASS и 13 scoped probe PASS; одно наблюдение с историей нового устройства')],[2.05,5.05])
sub('Восемь групп дефектов первого этапа')
table(['ID','Воспроизведённое поведение'],[
('UA-05.C12','Поздний групповой invite создаёт входящий после leave/ban и до join'),
('UA-13.C05/C06','Гонки stopActiveCapture пропускают нового владельца или незавершённый native stop'),
('UA-22.C07','Ошибка входа показывает внутренний minified runtime type'),
('UA-27.C08','После remote revoke web UI повреждён, composer исчезает; cached contacts обращаются к null userID'),
('UA-32.C05','Временное фото остаётся в уже открытой галерее после TTL'),
('UA-34.C05','Успешный enqueue после навигации сообщает ложную ошибку'),
('UA-70.C07','Отмена reply стирает ранее существовавший черновик'),
('UA-82.C01/C02','Глобальный поиск сохраняет скрытый результат или результат покинутой комнаты')],[1.5,5.6])
p('Отдельное наблюдение UA-24.C06: на новом устройстве сначала показан исходный текст вместо правки; после reload исправлено. Причина и срок сходимости не доказаны. Таймаут старого visual capture harness и квадраты шрифта в старом capture не объявлены дефектами продукта: обычный web отображал шрифт корректно.')
p('Старые аппаратные замечания владельца по UA-02/04/08/09/14/30 остаются открытыми в прежнем объёме. Их не отменяют эти лабораторные результаты.')

page('Новые выполненные проверки звонков')
table(['Уровень проверки','Результат и точные границы'],[
('Существующие модули','58 основных и 15 дополнительных Flutter PASS; 11 Python PASS. Разрешения, cleanup, media keys, уведомления, группы, layout, устройства, статистика и маршруты проверены по assertions модулей.'),
('Новые серверные границы','5 PASS: две комнаты; второе устройство; повтор старого leave после нового входа; чужой/cross-room lease; восстановление camera capability. Настоящая SQLite, synthetic SFU.'),
('Поздние события','1 PASS, 24 порядка connecting / ICE completed / DTLS connected / failed после отбоя. После каждого события kEnded; через 31 с hangup1 и answer0.'),
('Личное нативное аудио','3 цикла: два приняты с audio packets и DTLS; один отменён до ответа без захвата на принимающем peer. Remote hangup завершает вторую сторону.'),
('Нативная камера','3 стадии: off с ошибкой сигнализации, timeout, late sender. Реальный захват Mac освобождён; trackDispose раньше streamDispose; лишних native tracks нет.'),
('Личное нативное видео','Audio→video, декодируемые кадры и renderer, low 320×180, два off/on с возвратом кадров, удалённый конец и остановленная локальная камера.'),
('Групповое медиа','3 native LiveKit peer. Поздний C получает видео; B/C декодируют после off/on; неверный ключ останавливает только C; повторный вход C восстанавливает видео; A уходит, B/C продолжают и C принимает видео B.')],[1.55,5.55])
sub('Что доказывает групповой прогон')
p('На обоих получателях audio имеет GCM kOk и растущий RTP; источник заранее выключен, поэтому речь и акустическая разборчивость не оценивались. Для video проверены framesDecoded и размер кадра, а также отрицательный контроль неверным ключом. Это свидетельство реальной расшифровки видео в локальном SDK-стенде с синтетическим общим ключом.')
p('SDK 2.13.2 подключался к существующему локальному SFU через loopback. Вызовы авторизации Matrix, подтверждение устройств, распределение sender keys, production TURN и интерфейс группового звонка этим прогоном не проверены. Все участники находились на одном Mac; межплатформенного подтверждения нет.')

page('Новые дефекты и наблюдение')
sub('P1 Завершение блокируется зависшим управлением')
p('UA-07.C05/C06. Открыть production CallWindow с активным вызовом. Задержать завершение camera(false) либо mute. Нажать соответствующую кнопку: до выполнения операции кнопка «Завершить» имеет onPressed=null. Ожидается доступный отбой независимо от задержки вспомогательного действия. Оба widget assertions падают.')
p('Общая точка: call_window.dart — busy применяется к кнопке отбоя, а perform игнорирует новое действие, пока busy=true. Проверен реальный виджет с synthetic call и Completer; зависание физического драйвера не моделировалось. Свидетельства: call_ui_race_probe.dart и ui-races.txt.')
sub('P1 Отложенный возврат включает камеру в inactive')
p('UA-08.C09. Активный video call, camera(false) ещё ждёт. Отправить inactive → resumed → inactive, затем закончить выключение. Ожидается выключенная камера в последнем inactive; фактически cameraEnabled=true. Один controller assertion падает.')
p('Общая точка: CallController.didChangeAppLifecycleState. Очередь resumed проверяет прежний active call и isClosed, но не последнее lifecycle state. Проба вызывает production controller с synthetic camera. Фактическая съёмка или передача в фоне не утверждаются; риск необходимо проверить после исправления на native Mac и Android.')
sub('P2 Поздний discovery игнорирует потерю членства')
p('UA-05.C18. Отправить discovery из joined encrypted group, до HTTP200 изменить membership того же Room на leave либо ban. Ожидается отсутствие текущего вызова; фактически current содержит OngoingGroupCall в обоих вариантах. Два assertions падают.')
p('Общая точка: GroupCalls.find/refresh. Eligibility проверяется до await, после ответа проверяется прежний room object, но не текущее membership. Это дефект локального состояния карточки; обход серверного допуска или получение медиаключей не доказаны. Свидетельства: discovery_membership_probe.dart и discovery-races.txt.')
sub('Наблюдение в лаборатории SDK')
p('UA-05.C39. После намеренной подстановки неверного общего ключа C перестал декодировать видео, B продолжал. Простой возврат правильного ключа не дал роста framesDecoded за 25 с; повторный вход с новым receiver восстановил видео. Продукт распределяет ключи иначе, поэтому это исследовательский результат, не четвёртый новый баг приложения. UA-05.C26 закрыт только в объёме восстановления через повторный вход.')

page('Расширенная карта сценариев звонков')
p('Ниже — объём областей в едином реестре. Это обзор покрытия, а не второй список приёмки. Новые сценарии проверяют переходы и пересечения, которых не было в прежних формулировках; подслучаи не размножены на весь декартов продукт устройств и сетей.')
table(['Область','Всего','Добавлено'],[
('UA-04 Личные соединения и повторные вызовы','31','13'),
('UA-05 Группы и медиастенд','39','22'),
('UA-06 Несколько своих устройств','10','6'),
('UA-07 Окно звонка и доступность','12','8'),
('UA-08 Камера и переходы в видео','18','12'),
('UA-09 Громкость и аудиомаршруты','12','8'),
('UA-10 Качество и деградация','9','5'),
('UA-11 Индикаторы говорящего','8','4'),
('UA-12 Завершение и история','9','5'),
('UA-17 Разрешения и занятые устройства','10','6'),
('UA-18 Push и фоновые действия','12','6'),
('Всего в указанных областях','170','95')],[5.2,.95,.95])
sub('Пересечения для последующих сквозных прогонов')
p('Для личного и группового аудио и видео отдельно: Mac↔web, web↔web, Mac↔Android, Mac↔iPhone PWA, Android↔iPhone PWA, Safari↔PWA. В web различать Chromium, Safari и Firefox. Для группы смешать три платформы и проверить переход от 3 к 10 участникам.')
p('Сетевые точки: до ответа, при SDP, после подключения, при rekey и при отбое. Обрывы 1/5/10 с и 15/40/60 с; односторонний uplink/downlink; Wi-Fi→mobile; исправная сигнализация при потерянном медиа и обратное. Это запланированные варианты, не выполненная сеть реальных телефонов.')
p('Сроки различаются: личный transport deadline 15 с, group lease 30 с, invite 45 с. Отдельно проверять восстановление до и после границы; поздний успех не должен оживлять завершённую session.')
p('Новые 95 строк: 14 PASS в явно указанном объёме, 4 дефектных подслучая, 1 наблюдение, 44 открытых сквозных сценария и 32 с физическими/внешними условиями. Полные UA остаются открытыми, пока не выполнены их требования к реальным устройствам.')

page('План продолжения и оставшиеся ограничения')
sub('Сначала устранить воспроизведённые гонки')
p('Приоритет следующих изменений: независимый от busy отбой; проверка последнего lifecycle state перед camera resume; повторная eligibility после discovery; затем поздние group invites и гонки active_capture из первого этапа. Для каждого исправления сначала перевести конкретный падающий probe в PASS и проверить соседний переход. В этом аудите продуктовые исправления не выполнялись.')
sub('Затем выполнить полный путь приложения')
p('На отдельном исправном Matrix/control/SFU стенде провести группу A/B/C через обычный клиент: приглашение, auto trust неизменных устройств, sender keys, audio/video, выход создателя, rejoin, отзыв устройства и членства. Добавить packet loss и обрыв сигнализации отдельными контролируемыми fault injection. Текущий SDK-прогон не закрывает этот этап.')
sub('После этого проверить реальные платформы')
p('Отдельно выполнить Mac, физический Android/Xiaomi и iPhone Safari/PWA: слышимость, speaker/Bluetooth, запреты ОС, блокировка, push, background, камера, H264 и смена сети. Физические телефоны в этой сессии не управлялись; отсутствие ошибки на одном Mac не доказывает их работоспособность. При продуктовых изменениях соблюдать штатный выпуск и macOS update при затронутом клиенте.')
sub('Остаток и критерий готовности')
p('В реестре открыта 481 строка: 232 имеют только существующую авто-опору, 141 требует полного интеграционного пути, 108 — физических/внешних условий. Дополнительно остаются 14 дефектных подслучаев и 2 наблюдения. Ни один из этих пунктов не закрыт по предположению или по наличию настройки E2EE.')
p('Готовность означает подтверждённые шаги нужной версии на названных устройствах, отсутствие повторного дефекта и сохранённые результаты соседних путей. Не требуется заново принимать весь ранее успешный функционал без причины.')
sub('Свидетельства и состояние среды')
link('Единый реестр с полными шагами и устойчивыми ID',ROOT/'docs/user-acceptance.md')
link('Результаты и команды первого этапа',ROOT/'docs/iterations/scenario-audit-2026-11-01/results.json')
link('Результаты и команды этапа по звонкам',HERE/'results.json')
p('Публичные свидетельства не содержат credentials, ICE-паролей, SDP или приватного контента. Одноразовая SFU-комната удалена, приватный файл токенов удалён. SFU container ID, StartedAt и RestartCount совпадают с исходными; служба не перезапускалась. Временные интеграционные test entrypoints убраны; установленное приложение владельца продолжает прежний процесс.')
p('Дата отчёта — 2 ноября 2026 года. Этот документ фиксирует завершённый объём аудита и порядок дальнейших работ; актуальные статусы всегда находятся в реестре.')
d.core_properties.title='Аудит VoiceChat и проверка звонков'
d.core_properties.subject='Проверки приложения и план дальнейшей приёмки'
d.core_properties.author='Codex'
d.save(HERE/'voicechat-audit-2026-11-02.docx')
print('Created',HERE/'voicechat-audit-2026-11-02.docx')
