# Установка v2rayA 2.2.7.5-r2 из этого форка

Это legacy-вариант для OpenWrt 21.02 и совместимых фирменных прошивок с
`opkg` и `iptables/firewall3`. Встроен backport GeoIP memory fix из upstream
PR #1933. LuCI, UCI, procd и отдельно установленное ядро Xray сохраняются.

На GL.iNet GL-MT3600BE с архитектурой пакетов `aarch64_cortex-a53` пользователь
подтвердил корректную работу первоначального IPK. Это не означает проверки
всех режимов и длительного отсутствия роста памяти. Остальные архитектуры
пока имеют только проверки сборки и ELF; установщик прямо предупреждает об
отсутствии испытаний на реальном роутере. Другие устройства с
`aarch64_cortex-a53` тоже требуют собственного теста.

## Чистая установка с роутера

Все команды выполняются по SSH от root. Файлы с ПК заранее переносить не
нужно. Сначала дождитесь успешной публикации Releases в
`DragonSavA/v2raya-openwrt` после push патча: установщик берётся из готового
релиза, а не из ещё не собранной ветки.

1. Проверьте окружение и установите HTTPS-загрузчик:

   ```sh
   opkg print-architecture
   command -v fw3
   opkg update
   opkg install ca-bundle wget-ssl
   ```

   Этот вариант рассчитан на firewall3. На firewall4 или системе с `apk`
   установщик обновление не выполняет. Используйте пакеты kmod только из
   feed, соответствующего текущему ядру вашей прошивки.

2. Добавьте исходный feed v2rayA:

   ```sh
   wget -O /etc/opkg/keys/94cc2a834fb0aa03 \
     https://downloads.sourceforge.net/project/v2raya/openwrt/v2raya.pub
   feed_arch="$(. /etc/openwrt_release && printf '%s' "$DISTRIB_ARCH")"
   touch /etc/opkg/customfeeds.conf
   sed -i '/^src\/gz v2raya /d' /etc/opkg/customfeeds.conf
   printf 'src/gz v2raya https://downloads.sourceforge.net/project/v2raya/openwrt/%s\n' \
     "$feed_arch" >> /etc/opkg/customfeeds.conf
   opkg update
   ```

3. Установите базовый пакет, LuCI, Xray и зависимости firewall3:

   ```sh
   opkg install v2raya xray-core luci-app-v2raya
   opkg install iptables-mod-conntrack-extra iptables-mod-extra \
     iptables-mod-filter iptables-mod-tproxy kmod-ipt-nat6
   # При необходимости:
   # opkg install v2fly-geoip v2fly-geosite
   ```

   Убедитесь, что все команды завершились успешно. Пакеты ядра, LuCI и
   зависимостей остаются из прежних feeds; форк обновляет только `v2raya`.

4. Установите нашу версию поверх версии из feed:

   ```sh
   wget -O /tmp/install-v2raya-release.sh \
     https://github.com/DragonSavA/v2raya-openwrt/releases/latest/download/install-release.sh &&
   sh /tmp/install-v2raya-release.sh
   ```

   Скрипт выбирает поддерживаемую архитектуру с наибольшим приоритетом из
   `opkg print-architecture`, проверяет SHA-256, размер и метаданные IPK,
   сохраняет резервную копию на постоянном разделе и лишь после этого
   устанавливает `2.2.7.5-r2`. Если сборки нет, он сообщает об этом и
   оставляет установленную версию из feed. Ошибка сети/хеша тоже оставляет
   её без изменений. Версия новее `2.2.7.5-r2` автоматически не понижается.

   Обновление работающего сервиса кратковременно разрывает его соединения.
   Успех установки не заменяет функционального теста сети.

5. Проверьте результат и запустите сервис:

   ```sh
   opkg status v2raya
   /usr/bin/v2raya --version
   uci set v2raya.config.enabled='1'
   uci commit v2raya
   /etc/init.d/v2raya enable
   /etc/init.d/v2raya start
   ```

   В opkg ожидается `Version: 2.2.7.5-r2`; бинарник сообщает `2.2.7.5`.
   Откройте LuCI `Службы → v2rayA` и WebUI `http://<адрес-роутера>:2017`.
   Если скрипт сообщил об отсутствии сборки, продолжит работать версия из
   feed без нашего backport — не считайте такой результат установкой форка.

## Для уже установленного v2rayA

Достаточно шага 4. Новую настройку feed и установку ядра повторять не нужно.
UCI и база `/etc/v2raya` сохраняются, исходное состояние сервиса учитывается:
работавший сервис перезапускается, остановленный остаётся остановленным.
Прежнее включение/выключение автозапуска также сохраняется.

Проверка доступности без установки:

```sh
sh /tmp/install-v2raya-release.sh --check
```

Уже установленная `2.2.7.5-r2` повторно не устанавливается. Все новые
сборочные релизы имеют ту же версию пакета и разные теги коммитов. Для
осознанной переустановки нового релиза той же версии:

```sh
sh /tmp/install-v2raya-release.sh --reinstall
```

После успешной установки скрипт выставляет `opkg flag hold v2raya`, чтобы
feed не заменил наш пакет при общем обновлении. Разрешить замену вручную:

```sh
opkg flag ok v2raya
```

## Порядок тестирования

1. При наличии watchdog, перезапускающего v2rayA по памяти, остановите его
   на время наблюдения. Иначе он скроет рост памяти.
2. Проверьте версию, LuCI, вход в WebUI, сохранение серверов и подписок.
3. Проверьте запуск/остановку Xray, DNS, обычный proxy и используемый режим
   прозрачного прокси. При остановке v2rayA не должно остаться лишнего Xray,
   занимающего его служебный порт.
4. Посмотрите `logread -e v2raya` и ошибки ядра. Если ваш роутер перезагружался
   из-за OOM, учитывайте и потребление Xray, а не только процесса v2rayA.
5. Запишите 24–72 часа памяти при привычной нагрузке; сравните с прежней
   версией при сходной нагрузке. Специально отметьте обновление GeoIP,
   подписок и переподключения. Нужны отсутствие OOM/частых рестартов и
   стабильные соединения; один успешный старт этого не подтверждает.

Монитор можно скачать на самом роутере:

```sh
wget -O /tmp/router-memory-monitor.sh \
  https://raw.githubusercontent.com/DragonSavA/v2raya-openwrt/legacy-2.2.7.5-memfix/scripts/router-memory-monitor.sh
nohup sh /tmp/router-memory-monitor.sh 60 /root/v2raya-memory.csv \
  >/tmp/v2raya-memory-monitor.log 2>&1 &
echo $! >/tmp/v2raya-memory-monitor.pid
```

Следите за размером CSV на flash. Остановка:

```sh
kill "$(cat /tmp/v2raya-memory-monitor.pid)"
```

## Резервная копия и откат

Путь к резервной копии скрипт печатает перед установкой:
`/root/v2raya-backups/<дата-время>-<PID>/`. В ней находятся старый бинарник,
init-скрипт, UCI, база, файлы opkg и старый status-блок пакета. Каталог
закрыт от других пользователей; архив может содержать ваши аккаунты и
подписки. Скопируйте его на ПК для долговременного хранения.

При ошибке установки, невозможности запустить новый бинарник или
неудачном перезапуске скрипт автоматически восстанавливает копию. При
функциональной проблеме, которую вы обнаружили позже, выполните ручной
откат. Подставьте **конкретный путь**, напечатанный вашим запуском:

```sh
(
set -e
V2RAYA_BACKUP='/root/v2raya-backups/<дата-время>-<PID>'
test -s "$V2RAYA_BACKUP/files.tar.gz" &&
test -s "$V2RAYA_BACKUP/package-status.txt" || exit 1
/etc/init.d/v2raya stop
tar -xzf "$V2RAYA_BACKUP/files.tar.gz" -C /
awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /^Package: v2raya\n/ { print }' \
  /usr/lib/opkg/status > /tmp/v2raya-status-restored
cat "$V2RAYA_BACKUP/package-status.txt" >> /tmp/v2raya-status-restored
cp /tmp/v2raya-status-restored /usr/lib/opkg/status
rm -f /tmp/v2raya-status-restored
if [ "$(cat "$V2RAYA_BACKUP/was-enabled")" = 1 ]; then
  /etc/init.d/v2raya enable
else
  /etc/init.d/v2raya disable
fi
if [ "$(cat "$V2RAYA_BACKUP/was-running")" = 1 ]; then
  /etc/init.d/v2raya start
fi
opkg status v2raya
/usr/bin/v2raya --version
)
```

Не запускайте параллельно другие операции opkg во время установки/отката.
Не используйте `--force-depends` и `--force-architecture`.

Для нового неподдерживаемого роутера приложите к сообщению о результатах:
модель, версию прошивки/ядра, `uname -m`, `opkg print-architecture`, тег
релиза, версию Xray, режим firewall и результаты проверок выше.
