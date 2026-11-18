# gdmount

[English](README.md) · **Українська**

Монтування Google Drive у Linux через rclone. gdmount створює системну службу користувача та підтримує GNOME, KDE Plasma й інші стільниці.

## Можливості

- Встановлення rclone і fuse3
- Авторизація акаунта Google через браузер
- Ручний і автоматичний режими оновлення метаданих
- Монтування залежно від доступності мережі
- Оновлення кешу й стан черги вивантаження
- Заміна акаунта та повне видалення
- Інтерфейс українською та англійською

## Встановлення

```bash
curl -fsSL https://github.com/PanVena/gdmount/raw/refs/heads/main/gdrive-mount.sh | bash -s -- install
```

Або запустіть скрипт із репозиторію:

```bash
./gdrive-mount.sh install
```

Змінну `GDMOUNT_UI_LANG=uk|en` можна використовувати для вибору мови інтерфейсу. Якщо її не задано, gdmount визначає мову системи.

## Використання

```text
gdmount install [опції]         встановити й змонтувати
gdmount refresh [ТЕКА] [-r]     оновити кеш списків тек
gdmount refresh --all           оновити весь диск
gdmount status                  стан служби, монтування й кешу
gdmount mode [manual|auto]      показати або змінити режим оновлення
gdmount start | stop            запустити або зупинити диск
gdmount switch-account [опції]  змінити акаунт Google
gdmount uninstall [опції]       видалити створені gdmount файли
gdmount --help                  повна довідка
```

Налаштування зберігаються в `~/.config/rclone-gdrive-setup/config`.

## Режими оновлення

- `manual`: rclone не опитує Google самостійно; оновлюйте командою `gdmount refresh`.
- `auto`: rclone опитує Google раз на хвилину.

## Видалення

```bash
gdmount uninstall
```

Для видалення без підтверджень використайте `--yes`. Наявні файли на Google Drive ніколи не видаляються.

## Ліцензія

[MIT](LICENSE)
