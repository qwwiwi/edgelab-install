# EdgeLab AI Agent -- Quick Start

Установщик персонального AI-агента на базе Claude Code с Telegram-интерфейсом.

Одна команда -- и у вас свой AI-агент на VPS, который отвечает в Telegram.

## Установка

```bash
curl -fsSL https://edgelab.su/install | sudo bash
```

## Что устанавливается

| Компонент | Версия | Назначение |
|---|---|---|
| Node.js | 22.x | Среда для Claude Code CLI |
| Python | 3.12+ | Gateway и скрипты |
| Claude Code | latest | AI-агент (Anthropic, Opus -- код/ревью, Sonnet -- субагенты) |
| Telegram Gateway | latest | Связь агента с Telegram |
| Caddy | latest | Веб-сервер для вебхуков |
| UFW + fail2ban | -- | Безопасность сервера |

Дополнительно: curl, wget, git, jq, htop, tmux, build-essential.

## Архитектура

```
Telegram --> Bot API --> Gateway (Python) --> Claude Code --> ответ
                                  |
                           config.json
                           (bot token,
                            user ID,
                            workspace)
```

Gateway работает как systemd-сервис, получает сообщения из Telegram через long polling, передаёт их в Claude Code и отправляет ответ обратно.

## После установки

1. **Авторизуйте Claude Code** -- запустите `claude` в терминале, пройдите OAuth-авторизацию (Anthropic Max подписка, $100-200/мес)

2. **Настройте бота** -- откройте `~/claude-gateway/config.json`:
   - Создайте бота через [@BotFather](https://t.me/BotFather) в Telegram
   - Сохраните токен: `echo "YOUR_TOKEN" > ~/claude-gateway/secrets/bot-token`
   - Укажите свой Telegram user ID в `allowlist_user_ids`

3. **Запустите gateway**:
   ```bash
   sudo systemctl start claude-gateway
   sudo systemctl enable claude-gateway
   ```

4. **Напишите боту** -- агент ответит

## Требования

- **ОС:** Ubuntu 22.04 или 24.04
- **Архитектура:** amd64 или arm64
- **Ресурсы:** минимум 2 vCPU, 4 GB RAM
- **Подписка:** Anthropic Max ($100-200/мес) -- оплата картой на сайте Anthropic

## Рекомендации по VPS

Для запуска агента нужен VPS с Ubuntu. Проверенные провайдеры:

| Провайдер | Цена от | Локация | Ссылка |
|---|---|---|---|
| Timeweb Cloud | ~500 руб/мес | Россия, Нидерланды | [timeweb.cloud](https://timeweb.cloud/r/pt392094) |
| VDSina | ~500 руб/мес | Россия, Нидерланды | [vdsina.com](https://www.vdsina.com/?partner=6x47zemriu8q) |
| DigitalOcean | $12/мес | Европа, США | [digitalocean.com](https://m.do.co/c/63cded1ddfa3) |
| Hetzner | 7.99 EUR/мес | Германия, Финляндия | [hetzner.com/cloud](https://hetzner.com/cloud) |

Для пользователей из РФ рекомендуем Timeweb Cloud или VDSina (оплата рублями, серверы в РФ и EU).

## Структура файлов

```
~/claude-gateway/              # Telegram Gateway
  gateway.py                   # Основной скрипт
  config.json                  # Конфигурация
  secrets/                     # Токены (chmod 700)
    bot-token                  # Токен Telegram-бота

~/.claude/                     # Workspace агента
  CLAUDE.md                    # Инструкции для агента (SOUL)
  settings.json                # Настройки (контекстное окно 400К)
```

Для продвинутой архитектуры с памятью, скиллами и автоматизацией смотрите: [public-architecture-claude-code](https://github.com/qwwiwi/public-architecture-claude-code)

```
~/.claude/                     # Продвинутая архитектура (опционально)
  CLAUDE.md                    # SOUL: identity, роль, характер
  settings.json                # CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
  core/
    USER.md                    # Профиль владельца (@include)
    rules.md                   # Границы и запреты (@include)
    AGENTS.md                  # Модели, субагенты (on-demand)
    MEMORY.md                  # Архив (on-demand)
    LEARNINGS.md               # Уроки из ошибок (on-demand)
    warm/decisions.md           # Решения за 14 дней (@include)
    hot/handoff.md             # Последние 10 записей (@include)
    hot/recent.md              # Полный журнал (НЕ в контексте)
  tools/TOOLS.md               # Серверы, порты, Docker (on-demand)
  skills/                      # Скиллы агента
  hooks/                       # Git и session hooks
  scripts/                     # Cron-скрипты ротации памяти
```

4 файла загружаются при старте через @include (~7% от 400К). Остальные -- по запросу через Read tool.

## Настройка контекстного окна

Claude Code имеет базовое окно 1М токенов, но качество ответов лучше при 400К. Рекомендуем:

```bash
# Создайте settings.json (от имени пользователя, не root)
cat > ~/.claude/settings.json << 'EOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  }
}
EOF
```

Агент будет автоматически сжимать контекст при достижении 400К токенов.

## Полезные команды

```bash
# Статус gateway
sudo systemctl status claude-gateway

# Логи gateway
sudo journalctl -u claude-gateway -f

# Перезапуск после изменения config.json
sudo systemctl restart claude-gateway

# Обновить Claude Code
claude update
```

## Полное руководство

Пошаговый гайд с настройкой VPS, домена и агента:
**[https://guides.edgelab.su/guides/vps-ai-agent-setup/](https://guides.edgelab.su/guides/vps-ai-agent-setup/)**

## Сообщество

- Сайт: [https://edgelab.su](https://edgelab.su)
- Документация: [https://guides.edgelab.su](https://guides.edgelab.su)

## Лицензия

MIT
