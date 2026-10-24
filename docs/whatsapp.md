# WhatsApp и Kaspi: подключение

Интеграция работает через официальный **WhatsApp Cloud API** от Meta. Неофициальные шлюзы и «веб-версии» не используются.
С настоящим кабинетом Meta и с Kaspi эта интеграция пока **не проверялась**. Проверены только SQL-тесты и тесты функций с подменённой сетью.
Поэтому первое подключение проведите на тестовом номере Meta.

## 1. Обновление базы

В SQL Editor выполните один раз `supabase/updates/20261030000012_whatsapp_kaspi.sql`.

Обновление включает расширение `supabase_vault`. Если в проекте его нет, включите его в Database → Extensions → `supabase_vault` и выполните файл снова.

## 2. Две серверные функции (Edge Functions)

Каждая функция — один файл без зависимостей. Разверните её одним из двух способов.

**Через панель Supabase:**

1. Откройте Edge Functions → Deploy a new function → Via Editor.
2. Назовите функцию `whatsapp`, вставьте содержимое `supabase/functions/whatsapp/index.ts` и нажмите Deploy.
3. Таким же образом создайте функцию `whatsapp-webhook` из файла `supabase/functions/whatsapp-webhook/index.ts`.
4. У **обеих** функций откройте Details и выключите **Verify JWT** (Enforce JWT verification).

Почему Verify JWT выключен:

- Meta не присылает токен Supabase.
- Сотрудника проверяет сама база: функция `whatsapp` вызывает её с его токеном.
- Вебхук принимает только события с верной подписью Meta.

**Через Supabase CLI:**

```bash
supabase functions deploy whatsapp --no-verify-jwt
supabase functions deploy whatsapp-webhook --no-verify-jwt
```

Свои секреты функциям задавать не нужно. Адрес проекта и серверный ключ Supabase подставляет сам. Токен Meta хранится в Vault и вводится в CRM.

## 3. Кабинет Meta

1. Создайте или откройте **Meta Business** (business.facebook.com).
2. На developers.facebook.com создайте приложение типа **Business** и добавьте продукт **WhatsApp**.
3. В WhatsApp → API Setup добавьте номер санатория и подтвердите его по SMS или звонку. Скопируйте:
   - **Phone number ID**;
   - **WhatsApp Business Account ID**.
4. Выпустите постоянный токен:
   1. Откройте Business Settings → Users → System users.
   2. Создайте системного пользователя.
   3. Назначьте ему приложение и аккаунт WhatsApp (Assign assets).
   4. Нажмите Generate token с правами `whatsapp_business_messaging` и `whatsapp_business_management`.

   Временный токен со страницы API Setup живёт около суток, поэтому для работы он не подходит.
5. Скопируйте **App Secret** из App settings → Basic.
6. В CRM откройте **Настройки → WhatsApp Business (Cloud API)**:
   1. Введите Phone number ID, WABA ID, токен и App Secret и нажмите «Сохранить».
   2. Нажмите «Проверить подключение». Meta должна вернуть номер и название.
7. В CRM появятся **Callback URL** и **Verify token**. В приложении Meta откройте WhatsApp → Configuration → Webhooks:
   1. Вставьте оба значения и нажмите Verify and save.
   2. В Webhook fields подпишитесь на **messages**.
8. В WhatsApp Manager создайте шаблоны сообщений (например, подтверждение брони или напоминание) и дождитесь их утверждения.

## Правила WhatsApp, которые соблюдает CRM

- Обычный текст можно отправить только в течение 24 часов после последнего сообщения гостя.
- Вне этого окна, и для первого сообщения тоже, отправляется только утверждённый шаблон. Укажите его имя и язык, например `ru`.
- В раздел «WhatsApp» входящие попадают, только если вебхук настроен и сохранён App Secret.
- Статусы «Доставлено» и «Прочитано» приходят от Meta через тот же вебхук.
- Переписки Meta оплачиваются по тарифам Meta на аккаунте санатория. CRM за сообщения ничего не берёт.

## Kaspi

У Kaspi нет открытого API для приёма платежей. Kaspi Pay подключается через Kaspi Business, поэтому CRM не создаёт счета и не узнаёт об оплате сама.

1. В Kaspi Business получите ссылку или QR для оплаты.
2. Вставьте ссылку в **Настройки → Оплата через Kaspi**. Принимается только адрес `https://…kaspi.kz/…`.
3. В брони с остатком к оплате появится блок «Оплата через Kaspi»:
   - сообщение с суммой и ссылкой можно скопировать;
   - его же можно отправить гостю через WhatsApp.
4. Когда деньги придут, отметьте оплату в брони вручную способом «Kaspi перевод».
