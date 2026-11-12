> Историческая заметка из предыдущего выпуска. В работе 0.9.5 источники не открывались; текущие результаты — verification.json и DEVELOPMENT_STATUS.md.

# GitHub Actions: runner не выделен — 12 ноября 2026

Скриншот запуска №22 содержит ошибку `The job was not acquired by Runner of type hosted even after multiple attempts` и предупреждения о capacity macOS arm64. Ни checkout, ни Swift/Xcode в этом запуске не начались. Он не подтверждает ошибку компиляции Luma и не проверяет работу сигналов.

При первоначальной проверке [GitHub Status](https://www.githubstatus.com/incidents/dvy0t3mvh1lg) сообщал о проблемах Actions, Pages и Copilot; Actions был помечен как Major Outage. Связь именно запуска №22 с этим инцидентом без ссылки и времени запуска не установлена.

К завершению работы официальный status API уже вернул Actions=operational, All Systems Operational, без активных инцидентов. Последнее обновление страницы — 12 ноября, 02:21 по Asia/Qyzylorda. Ответ сохранён в `github-status-observation.json`. Это состояние сервиса при проверке, не подтверждение успешного запуска Luma.

## Изменение 0.9.3 (19)

В workflow выбран стандартный `macos-15-intel` вместо `macos-15`, который сейчас соответствует ARM64. Это обход ограничений ARM-пула, а не гарантия доступности GitHub.

[Официальная таблица runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) различает Intel и ARM64. [Образ macOS 15 Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) содержит Xcode 26.3 по прежнему пути `/Applications/Xcode_26.3.app`. Платформа сборки iPhone остаётся `generic/platform=iOS`: Intel-хост продолжает собирать arm64 iPhone binary.

В существующий шаг проверки добавлен вывод архитектуры runner и пути Xcode. Обязательные XCTest, AVFoundation, queue-harness, build и условия упаковки IPA сохранены. Исходники приложения, ресурсы, разрешения и подпись не менялись. Номер приложения повышен до 0.9.3 (19), проверка версии IPA обновлена.

## Как применить

1. Скопировать **содержимое V.0.9.3** в корень репозитория: рядом должны находиться `.github` и `Luma`. Не загружать внешнюю папку V.0.9.3 поверх прежнего корня.
2. Создать новый commit в `main`. Он запустит исправленный workflow; можно также использовать Actions → Luma - finite four-second cues → Run workflow для новой ревизии.
3. Дождаться восстановления GitHub Actions, если общий инцидент продолжается.
4. Убедиться в новом запуске, что runner — Intel/X64, а Xcode — 26.3. После этого проверять результаты реальных шагов сборки.

**Re-run jobs у старого запуска №22 не применяет новый YAML:** повторный запуск использует прежнюю ревизию. Для переключения runner нужен новый commit/run. [Документация GitHub о повторных запусках](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs) подтверждает сохранение исходных GITHUB_SHA и GITHUB_REF.

Новый workflow из этой среды в GitHub не отправлялся и не запускался. Успешная сборка и новый IPA пока не подтверждены.
