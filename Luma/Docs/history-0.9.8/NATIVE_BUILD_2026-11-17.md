# Нативная сборка Lumenoir 0.9.8 (27)

По прямому запросу и отдельному разрешению пользователя исходники и технические документы отправлены через GitHub Desktop из V.0.9.8/Luma/.validation-tools/ci-repo в brewmaster123/Luma, ветку luma/0.9.8-lumenoir.

Проверенный коммит: 30ea0d50b7bd9e2299877fe414692f8e56db2783. [CI](https://github.com/brewmaster123/Luma/actions/runs/44076006890) прошла с первой попытки. Исходники приложения после отправки не менялись; исправления компиляции не потребовались.

- 130 XCTest, 0 failures.
- 8 AVFoundation cases и отклонение повреждённого аудио.
- 34 сценария очереди с fake system backend и настоящими native Task.
- Сохранность механизма и комплектность английского перевода.
- Generic device builds iPhone и Apple Watch, затем упаковка IPA.

[Скачать IPA](https://github.com/brewmaster123/Luma/actions/runs/44076006890/artifacts/14325557397). [ZIP с IPA](https://github.com/brewmaster123/Luma/actions/runs/44076006890/artifacts/14325711888). Локальная копия: dist/Lumenoir-0.9.8-build27-unsigned.ipa.

SHA-256 IPA: c33ef40c59473b5e31be9a99f6248da5fdf1f1645eae000e3dab8c89adaf2e2a. SHA архива логов и ZIP с IPA сверены с официальными GitHub artifact digests перед извлечением; SHA самой IPA также совпал. Имена обоих приложений — Lumenoir; версия 0.9.8, build 27; прежние bundle ID. Проверены ARM Mach-O и отсутствие LC_CODE_SIGNATURE, ZIP-целостность, en/ru.lproj, неизменные WAV/дождь и шрифты. 170 локальных project inputs совпадают с коммитом CI. IPA неподписанная; устанавливать прежним способом.

Физический iPhone/Watch не проверялся. Отметки о 20-секундном Stop и дизайне на устройстве остаются непроверенными. См. DEVICE_TESTS.md.

Контроль старых папок: GitHub Desktop автоматически дописал одну строку в reflog origin/HEAD старого checkout V.0.9.6 (1577 → 1731 байт). Исходники, ресурсы, архив, прежняя IPA и остальные проверенные файлы не изменены. Ничего в старой папке не восстанавливалось, ожидаемые хеши не изменялись. Подробности: build-history-audit.json.
