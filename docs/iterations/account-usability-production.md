# Ключ восстановления, настройки и устройства — публикация 25 октября 2026

Коммит `30baeec657cb22bdaff39885a3c8f5ed9f998001` влит в `main` и опубликован на
[univc.duckdns.org](https://univc.duckdns.org/). [Build and deploy #18](https://github.com/kerbermeister/voicechat/actions/runs/40180556846)
завершён успешно за 3 мин 41 с, `mode=web`, `deploy=true`.

В обоих окнах создания ключа есть отдельное read-only поле, кнопки копирования
и сохранения `voicechat-recovery-key.txt` в UTF-8. Нижняя область мобильных
настроек уменьшена без сокращения размера нажатия. Устройства получают
доступные модели/типы, ОС и браузеры; произвольные пользовательские имена
сохраняются, скрытые браузером модели не угадываются.

Локально прошли 200 Flutter-тестов, 3 опциональных теста снимков пропущены;
анализатор без замечаний. Собраны release web и debug APK arm64. Проверены
точные байты экспорта и обратное декодирование синтетического ключа через SDK,
отмена/ошибки, read-only поле, мобильная геометрия при 320×568 и тексте 200%,
распознавание типов устройств и сохранение пользовательских имён. CI повторил
серверные и клиентские проверки перед production-сборкой.

Guard подтвердил backend fingerprint
`29590658203d07248e633165c18c1f7b2c77211527fd0e0f97fcf77b98ceb221`.
`current.json` и фактический web image соответствуют `30baeec`. Control image,
ID/StartedAt/RestartCount PostgreSQL, Synapse, control и TURN совпадают со снимком
до выпуска. Все службы running/healthy. `previous.json` указывает на
`3bfebcb143a26fa23dd513abeb5a6b3faaf27221`, предыдущий каталог сохранён.
Для этого web-only обновления новый backup с остановкой backend не создавался.

Публичные клиент, health, Matrix API, worker, WASM и локальный Inter TTF отвечают
200; закрытые admin/internal routes — 404. SHA-256 публичного `main.dart.js`
совпал с контейнером: `6f11450922a3dfa544611d7e9221c8c922e913f8dc3367b134d0897a014511e9`.
Сохранены `Cache-Control: no-cache`, COOP и COEP. Во встроенном браузере экран
входа загрузился без ошибок консоли; формы не отправлялись.

Локальный стенд [localhost:7362](http://localhost:7362/) обновлён той же клиентской
ревизией с локальными endpoints; backend healthy. [Контракт и ограничения](../tasks/10-account-usability.md),
[машиночитаемая проверка](account-usability-release-evidence/verification.json),
[успешный workflow](account-usability-release-evidence/workflow-success.jpg).

Нативный выбор файла и скачивание через браузер на физических устройствах
не проверены; сборки и platform/widget-тесты не заменяют эту приёмку.
Автоматическое завершение регистрации после подтверждения почты записано
отдельной TODO и в этот выпуск не входит.
