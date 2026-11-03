# Повторы receiver key в настоящем SDK/SFU

03.11.2026, после опубликованного59. H02/OPT-07/10, единая очередь
[UA-05.C39/C40](../../user-acceptance.md#ua-05). Только test target/tool;
приложение, ключи шифрования владельца и настройки ratchet прежние.

20 повторов одного initial sender-specific key в том же slot0 через номинальную
паузу9с (не менее3мин), без нового receiver/transport между повторами. Счётчик
берётся непосредственно перед каждым setRawKey; decodedAfter требует >5 новых
кадров после установки. Кадры, полученные во время9с ожидания, не подменяют PASS.

[Настоящий Mac SDK/SFU](macos.json):20/20, первый241→247, последний4812→4823,
минимум6 новых наблюдаемых framesDecoded. [Android API35](android.json):20/20,
82→88 и1592→1599, минимум6. Камера Mac и эмулируемая камера Android, только
loopback SFU с закреплённым production image; нет Matrix/account/media recording.
Прежние controls прошли: missing key блокирует, pre-native sender cryptor0 decoded,
новая publication/prepared slot и full reconnect восстанавливают decoding
(после reconnect по8 наблюдаемых frames). Native post-startup counters наблюдателя
сами по себе не доказывают содержимое; это ограничение сохраняется.

Android SDK helper PASS/receipt сохранён, но внешний runner вернул1 из-за ожидания
завершения эмулятора дольше40с. После этого агент сверил отсутствие owned QEMU,
пустой ADB и удалённый SFU; в локальный runner добавлен bounded terminate/kill
fallback. Это [ошибка teardown](android-cleanup.json), не провал медиатестов;
команду целиком успешной не объявляем. Физический Xiaomi не проверен.

[Канонический установленный59 восстановлен](owner-restored.json): прежние
account/device и выбранная старая QA-история; профиль/Keychain не очищались.
Сам по себе повтор одного верного ключа не воспроизвёл быстрый stall в этих
двух прогонах. Неверный ключ/ratchet rollback, длительный E2EE A/V, реальная
сеть и membership epochs этим не закрыты. Дедупликация или отключение ratchet
в продукте по этой пробе не вводились.
