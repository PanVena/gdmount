# shellcheck shell=bash disable=SC2034
# i18n.sh — gdmount interface translations.
# Source strings are in Ukrainian; GDMOUNT_EN contains English translations.
#
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Pan Vena

gdmount_detect_lang() {
  local v
  for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    [[ -n "$v" ]] || continue
    [[ "${v,,}" == uk* ]] && echo uk || echo en
    return 0
  done
  echo en
}

_() {
  local s="$1"; shift
  if [[ "${GDMOUNT_UI_LANG:-uk}" == en ]]; then
    if [[ -n "${GDMOUNT_EN[$s]+x}" ]]; then
      s="${GDMOUNT_EN[$s]}"
    else
      local from to
      for from in "${!GDMOUNT_EN_PARTS[@]}"; do
        to="${GDMOUNT_EN_PARTS[$from]}"
        s="${s//$from/$to}"
      done
    fi
  fi
  if (($#)); then printf -- "$s" "$@"; else printf '%s' "$s"; fi
}

declare -gA GDMOUNT_EN_PARTS=(
  ["Змінити:"]="Change:"
  ["Потрібне значення для"]="A value is required for"
  ["Старий акаунт:"]="Old account:"
  ["новий:"]="new:"
  ["Усе, що створив скрипт, прибрано."]="Everything created by this script has been removed."
  ["Налаштування Google Drive через rclone"]="Google Drive setup through rclone"
  ["Стан Google Drive (rclone)"]="Google Drive status (rclone)"
  ["Видалення налаштувань Google Drive"]="Uninstall Google Drive settings"
  ["Зміна акаунту Google Drive"]="Switch Google Drive account"
  ["Оновлення списків файлів"]="Refreshing file lists"
  ["Готово."]="Done."
  ["Немає з'єднання з інтернетом. Підключіться до мережі й повторіть."]="No internet connection. Connect to the network and try again."
  ["Не запускайте від root: сервіс має працювати від вашого користувача."]="Do not run as root: the service must run under your user."
  ["fusermount не знайдено. Встановіть пакет fuse3."]="fusermount was not found. Install the fuse3 package."
  ["Встановлюю rclone та fuse3 (потрібен sudo)..."]="Installing rclone and fuse3 (sudo required)..."
  ["Встановлено:"]="Installed:"
  ["rclone вже встановлено:"]="rclone is already installed:"
  ["Перевірка rclone та FUSE"]="Checking rclone and FUSE"
  ["Перевірка"]="Checking"
  ["Remote «"]="Remote \""
  ["» налаштовано"]="\" is configured"
  ["» не знайдено"]="\" was not found"
  ["» для Google Drive"]="\" for Google Drive"
  ["для Google Drive"]="for Google Drive"
  ["Remote вже існує, авторизацію пропускаю."]="The remote already exists; skipping authorization."
  ["Зараз відкриється браузер для входу в Google-акаунт."]="A browser will open to sign in to the Google account."
  ["Без графічної сесії: виконайте"]="Without a graphical session, run"
  ["на іншій машині."]="on another machine."
  ["Remote створено."]="Remote created."
  ["Перевіряю доступ до диска..."]="Checking access to the drive..."
  ["Доступ до Google Drive є."]="Access to Google Drive is available."
  ["Не вдалося отримати доступ до"]="Could not access"
  ["Перевірте:"]="Check:"
  ["Тека монтування"]="Mount directory"
  ["Тека існує і порожня:"]="The directory exists and is empty:"
  ["Вже змонтовано, перемонтую після оновлення сервісу."]="Already mounted; remounting after service update."
  ["не порожня. Оберіть іншу теку (--mount) або очистіть цю."]="is not empty. Choose another directory (--mount) or clear this one."
  ["Створено"]="Created"
  ["Знайдено «завислу» точку монтування"]="Found a stale mount point"
  ["залишок від попереднього запуску rclone"]="left over from a previous rclone run"
  ["Завислу точку розмонтовано"]="Stale mount point unmounted"
  ["Не вдалося розмонтувати. Виконайте вручну:"]="Could not unmount. Run manually:"
  ["systemd-сервіс користувача"]="user systemd service"
  ["Записано"]="Saved"
  ["Автозапуск налаштовано: диск монтується, лише коли з'являється мережа."]="Auto-start configured: the drive mounts only when network access is available."
  ["Без мережі нічого не працює й не опитує систему (CPU не витрачається)."]="Without a network, nothing runs or polls the system (no CPU usage)."
  ["NetworkManager не знайдено: без мережі сервіс повторює спробу кожні 10 с."]="NetworkManager was not found: without a network the service retries every 10 seconds."
  ["Сервіс увімкнено (автозапуск при вході в систему)."]="Service enabled (auto-start at login)."
  ["Очікування монтування"]="Waiting for mount"
  ["Google Drive змонтовано в"]="Google Drive mounted at"
  ["Монтування не з'явилося за 30 с. Подивіться логи:"]="Mount did not appear within 30 seconds. Check the logs:"
  ["Команда gdmount"]="gdmount command"
  ["Режим manual: Google сам не опитується"]="Manual mode: Google is not polled automatically"
  ["Режим auto: Google опитується кожні"]="Automatic mode: Google is polled every"
  ["змінити:"]="change with:"
  ["Команди:"]="Commands:"
  ["Оновити списки:"]="Refresh lists:"
  ["Статус:"]="Status:"
  ["Зупинити:"]="Stop:"
  ["Запустити:"]="Start:"
  ["Інший акаунт:"]="Another account:"
  ["Видалити все:"]="Remove all:"
  ["Логи:"]="Logs:"
  ["Порада:"]="Tip:"
  ["виключіть"]="exclude"
  ["з індексації"]="from indexing"
  ["інакше індексатор може почати качати весь диск."]="otherwise the indexer may start downloading the whole drive."
  ["Пакет"]="Package"
  ["rclone не встановлено"]="rclone is not installed"
  ["Сервіс"]="Service"
  ["Сервіс не встановлено"]="Service is not installed"
  ["Сервіс не знайдено, пропускаю"]="Service not found; skipping"
  ["Файл:"]="File:"
  ["Активний:"]="Active:"
  ["Автозапуск:"]="Auto-start:"
  ["за появою мережі"]="on network availability"
  ["спостерігач:"]="watcher:"
  ["Режим оновлення"]="Refresh mode"
  ["опитування Google:"]="Google polling:"
  ["вимкнено"]="disabled"
  ["кожні"]="every"
  ["Монтування"]="Mount"
  ["Змонтовано:"]="Mounted:"
  ["Не змонтовано:"]="Not mounted:"
  ["зависла"]="stale"
  ["rclone не працює"]="rclone is not running"
  ["Виправити:"]="Fix:"
  ["Кеш"]="Cache"
  [" у "]=" in "
  ["Кешу немає"]="No cache"
  ["ліміт"]="limit"
  ["зберігання до"]="retained for"
  ["Вивантаження"]="Uploads"
  ["Чекає вивантаження файлів:"]="Files waiting for upload:"
  ["вивантажуються через"]="uploaded after"
  ["після закриття/збереження"]="after close/save"
  ["Не вимикайте комп'ютер і не запускайте"]="Do not shut down the computer or run"
  ["доки це не стане 0."]="until this reaches 0."
  ["Усе вивантажено (черга порожня)"]="Everything is uploaded (queue is empty)"
  ["Файли, які зараз відкриті в програмі, потрапляють у чергу лише після закриття або збереження."]="Files currently open in applications enter the queue only after close or save."
  ["Буде виконано:"]="The following will be done:"
  ["зупинено й вимкнено сервіс"]="the service will be stopped and disabled"
  ["розмонтовано"]="unmounted"
  ["видалено файл сервісу"]="the service file will be removed"
  ["видалено автозапуск за мережею (якщо є)"]="network auto-start will be removed (if present)"
  ["видалено команду gdmount та збережені налаштування"]="the gdmount command and saved settings will be removed"
  ["видалено кеш"]="the cache will be removed"
  ["прибрано теку"]="the directory will be cleaned up"
  ["лише якщо порожня"]="only if it is empty"
  ["окремо запитаю про remote"]="you will separately be asked about remote"
  ["і пакет rclone"]="and the rclone package"
  ["Файли на самому Google Drive НЕ видаляються."]="Files on Google Drive itself are NOT deleted."
  ["Продовжити?"]="Continue?"
  ["Скасовано."]="Cancelled."
  ["Невивантажені файли лишаться в кеші, якщо ви не підтвердите їх видалення."]="Files that have not been uploaded will remain in the cache if you do not confirm deleting them."
  ["Зупинка сервісу"]="Stopping the service"
  ["Спостерігача за мережею зупинено й вимкнено"]="Network watcher stopped and disabled"
  ["Сервіс зупинено й вимкнено"]="Service stopped and disabled"
  ["Розмонтування"]="Unmounting"
  ["Не змонтовано, пропускаю"]="Not mounted; skipping"
  ["Розмонтовано"]="Unmounted"
  ["Не вдалося розмонтувати"]="Could not unmount"
  ["можливо, файли відкриті в програмах"]="possibly because files are open in applications"
  ["Файл сервісу"]="Service file"
  ["Видалено"]="Removed"
  ["Файлу немає, пропускаю"]="File absent; skipping"
  ["Кешу немає, пропускаю"]="No cache; skipping"
  ["Тека монтування"]="Mount directory"
  ["Видалено порожню теку"]="Removed empty directory"
  ["не порожня, залишаю без змін"]="is not empty; leaving unchanged"
  ["Нічого видаляти"]="Nothing to remove"
  ["Remote та пакет"]="Remote and package"
  ["існував до цього скрипта"]="existed before this script"
  ["не видаляю"]="not removing"
  ["немає запису"]="no record"
  ["чи створював remote цей скрипт"]="whether this script created the remote"
  ["Видалити remote"]="Remove remote"
  ["Remote видалено"]="Remote removed"
  ["Remote залишено"]="Remote left unchanged"
  ["rclone не встановлювався цим скриптом, пакет не чіпаю."]="rclone was not installed by this script; leaving the package unchanged."
  ["Немає запису, чи встановлював rclone цей скрипт."]="No record exists whether this script installed rclone."
  ["з --yes пакет невідомого походження не видаляю."]="With --yes, packages of unknown origin are not removed."
  ["Видалити пакет rclone?"]="Remove the rclone package?"
  ["Пакет rclone видалено"]="The rclone package was removed"
  ["Пакет fuse3 залишено, бо його можуть використовувати інші програми."]="The fuse3 package was left installed because other applications may use it."
  ["Пакет залишено"]="Package left installed"
  ["Запис стану збережено"]="State record retained"
  ["щоб наступний uninstall знову запитав про залишене."]="so the next uninstall asks again about remaining items."
  ["Усе, що створив скрипт, прибрано."]="Everything created by this script has been removed."
  ["Акаунт:"]="Account:"
  ["Акаунт"]="Account"
  ["Стара"]="Old"
  ["Новий"]="New"
  ["Чекаю, поки вивантажаться файли"]="Waiting for files to upload"
  ["до"]="for up to"
  ["с..."]="seconds..."
  ["Усе вивантажено."]="Everything is uploaded."
  ["Досі не вивантажено файлів:"]="Files are still not uploaded:"
  ["У кеші"]="In the cache"
  ["файл(ів) ще не вивантажено на Google Drive."]="file(s) have not been uploaded to Google Drive."
  ["Після очищення ці зміни буде втрачено."]="These changes will be lost after clearing."
  ["Самі файли лежать у"]="The files are located in"
  ["Все одно очистити кеш?"]="Clear the cache anyway?"
  ["Немає зв'язку з Google Drive, тож перевірити, що все вивантажено, неможливо."]="No connection to Google Drive, so it cannot be verified that everything is uploaded."
  ["Якщо в кеші"]="If"
  ["лежать зміни, яких ще немає на диску, після очищення їх буде втрачено."]="contains changes not yet on the drive, they will be lost after clearing."
  ["Немає ключа керування. Виконайте: gdmount install"]="The control key is missing. Run: gdmount install"
  ["Не вдалося виконати команду через rclone rc:"]="Could not execute the rclone RC command:"
  ["Якщо сервіс створено старою версією скрипта, виконайте:"]="If the service was created by an older script version, run:"
  ["Невідомий пакетний менеджер. Встановіть rclone і fuse3 вручну."]="Unknown package manager. Install rclone and fuse3 manually."
  ["Невідомий пакетний менеджер, видаліть пакет"]="Unknown package manager; remove the package"
  ["вручну."]="manually."
  ["Команду встановлено:"]="Command installed:"
  ["немає в PATH. Додайте в ~/.bashrc:"]="is not in PATH. Add this to ~/.bashrc:"
  ["Невідомий режим"]="Unknown mode"
  ["Доступні:"]="Available:"
  ["Сервіс зараз не змонтовано"]="The disk is not mounted"
  ["немає мережі чи сервіс зупинено"]="there is no network or the service is stopped"
  ["Дивіться:"]="See:"
  ["Немає інтернету. Оновлення без мережі лише зітре збережені списки тек."]="No internet. Offline refresh would only erase saved directory listings."
  ["Читаю весь диск"]="Reading the whole drive"
  ["На великому диску це може тривати хвилини..."]="On a large drive this may take several minutes..."
  ["Усі теки перечитано."]="All directories were refreshed."
  ["Перечитую"]="Refreshing"
  ["корінь диска"]="drive root"
  ["Готово."]="Done."
  ["Кеш списків тек очищено. Свіжі дані підтягнуться, коли ви відкриєте теки."]="The directory-list cache was cleared. Fresh data will load when you open directories."
  ["Відкриті вікна файлового менеджера оновіть (F5)."]="Refresh open file-manager windows (F5)."
  ["Режим уже"]="This mode is already"
  ["нічого міняти."]="nothing to change."
  ["Перемикаю на режим"]="Switching to mode"
  ["Сервіс буде перезапущено, диск на кілька секунд розмонтується."]="The service will restart and the drive will be unmounted briefly."
  ["Диск і автозапуск за мережею зупинено. Запустити знову:"]="The drive and network auto-start are stopped. Start again:"
  ["Запущено, диск змонтується за кілька секунд."]="Started; the drive will mount within a few seconds."
  ["Запущено, диск змонтується, щойно з'явиться мережа."]="Started; the drive will mount as soon as the network becomes available."
  ["Запущено."]="Started."
  ["Невідома опція:"]="Unknown option:"
  ["див. --help"]="see --help"
  ["Зайвий аргумент:"]="Unexpected argument:"
  ["Невідома команда:"]="Unknown command:"
  ["Доступні команди:"]="Available commands:"
)

declare -gA GDMOUNT_EN=(
  [$'Режим manual: Google сам не опитується (змінити: gdmount mode auto).']=$'Manual mode: Google is not polled automatically (change with: gdmount mode auto).'
  [$'Режим auto: Google опитується кожні %s (змінити: gdmount mode manual).']=$'Automatic mode: Google is polled every %s (change with: gdmount mode manual).'
  [$'Встановлення gdmount']=$'gdmount installation'
  [$'Налаштування рідного Google Drive для Linux']=$'Native Google Drive setup for Linux'
  [$'Використання: gdmount КОМАНДА [ОПЦІЇ]']=$'Usage: gdmount COMMAND [OPTIONS]'
  [$'Команди:']=$'Commands:'
  [$'встановити й змонтувати']=$'install and mount'
  [$'стан сервісу, монтування та кешу']=$'service, mount and cache status'
  [$'оновити кеш списків теки']=$'refresh directory listing cache'
  [$'показати або змінити режим оновлення']=$'show or change refresh mode'
  [$'запустити диск і автозапуск за мережею']=$'start the drive and network auto-start'
  [$'зупинити диск і автозапуск за мережею']=$'stop the drive and network auto-start'
  [$'змінити акаунт Google']=$'switch Google account'
  [$'видалити створені скриптом файли й налаштування']=$'remove files and settings created by the script'
  [$'Режими оновлення:']=$'Refresh modes:'
  [$'ручний — оновлення за командою gdmount refresh']=$'manual — refresh with gdmount refresh'
  [$'автоматичний — rclone опитує Google раз на хвилину']=$'automatic — rclone checks Google once per minute'
  [$'Опції:']=$'Options:'
  [$'Імʼя rclone remote']=$'rclone remote name'
  [$'тека монтування']=$'mount directory'
  [$'максимальний розмір кешу файлів']=$'maximum file cache size'
  [$'час збереження файлів у кеші']=$'file cache retention time'
  [$'manual або auto']=$'manual or auto'
  [$'як часто опитувати Google про зміни']=$'how often to poll Google for changes'
  [$'затримка перед вивантаженням закритого файлу']=$'delay before uploading a closed file'
  [$'не питати підтвердження']=$'do not ask for confirmation'
  [$'разом із підтеками']=$'including subdirectories'
  [$'оновити весь диск']=$'refresh the whole drive'
  [$'показати довідку']=$'show help'
  [$'Потрібна опція: %s']=$'A value is required for %s'
  [$'Невідома опція: %s (див. --help)']=$'Unknown option: %s (see --help)'
  [$'Невідома команда: %s']=$'Unknown command: %s'
  [$'Доступні команди: install, refresh, mode, status, start, stop, switch-account, uninstall']=$'Available commands: install, refresh, mode, status, start, stop, switch-account, uninstall'
  [$'Зайвий аргумент: %s (див. --help)']=$'Unexpected argument: %s (see --help)'
  [$'Скасовано.']=$'Cancelled.'
)
