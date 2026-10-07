# Установка и проверка v2rayA 2.2.7.5-r3 + Xray 26.3.27

Эта ветка предназначена для OpenWrt с **opkg и firewall3/iptables**, включая
GL.iNet GL-MT3600BE с OpenWrt 21.02-SNAPSHOT, ядром 5.4.281 и архитектурой
`aarch64_cortex-a53`. Сохраняются GeoIP backport, UCI, procd и интеграция LuCI.
Новый backend-патч добавляет Hysteria2 через нативный outbound Xray;
вспомогательные proxy-процессы и sing-box на роутере не устанавливаются.

Релиз содержит два IPK для каждой из девяти архитектур:
`v2raya_2.2.7.5-r3_<arch>.ipk` и `xray-core_26.3.27-r1_<arch>.ipk`.
Прежняя r2 работала на GL-MT3600BE по сообщению владельца. Это не означает,
что r3, новый Xray и Hysteria2 уже проверены на устройстве. Другие архитектуры
имеют сборочные/ELF-проверки; installer предупреждает об отсутствии теста
на реальном роутере. Локальные TCP/UDP-тесты выполняются на x86_64.

## Перед обновлением

Xray 26.3.27 **отклоняет `allowInsecure: true` после 2026-06-01**. В первую
очередь проверьте существующие Trojan и VLESS WS+TLS: сертификат сервера
должен быть действующим, доверенным и соответствовать SNI. Отключите пропуск
проверки сертификата в настройках клиента/выдаваемых S-UI ссылках, обновите
подписку и убедитесь, что эти узлы работают с прежним ядром. Одна замена
`insecure=1` на `0` не исправляет недоверенный сертификат или неправильный SNI.
Для собственного CA сначала настройте доверие к нему на роутере.

Installer проверяет текущий `/etc/v2raya/config.json` и дополнительный
каталог `v2raya.config.v2ray_confdir`. Неактивные узлы, не включённые в эту
конфигурацию, автоматически не проверяются. Проверьте их по очереди в WebUI
до обновления; после обновления также нужен тест подключения каждого типа.
Другие удалённые Xray настройки/транспорты или отсутствующие GeoIP/geosite
тоже могут остановить preflight. Скрипт не исправляет их молча.

Проверьте выбранное ядро и версии:

```sh
opkg status v2raya xray-core
/usr/bin/xray version
uci -q get v2raya.config.v2ray_bin
opkg print-architecture
df -h /overlay /tmp
```

Пустой `v2ray_bin` означает автоопределение: Xray имеет приоритет. Если явно
указан V2Ray или нестандартный путь, сначала осознанно выберите установленный
Xray в LuCI либо через UCI, проверьте прежние протоколы, затем запускайте
installer:

```sh
uci set v2raya.config.v2ray_bin='/usr/bin/xray'
uci commit v2raya
/etc/init.d/v2raya restart
```

Installer управляет только стандартным `/usr/bin/xray`; нестандартный бинарник
он не заменяет. Более новый Xray автоматически не понижается, но проходит
проверку поддержки нативного Hysteria2 и текущей конфигурации. Независимый
сервис `/etc/init.d/xray`, если он запущен, нужно остановить на время
обновления общего бинарника. Не выполняйте параллельно другие операции opkg.

## Чистая установка

Все команды выполняются на роутере от root; передавать файлы с ПК не нужно.
Сначала дождитесь успешного Release **r3** в этом форке.

1. Установите загрузчик HTTPS из feeds самой прошивки:

   ```sh
   opkg update
   opkg install ca-bundle wget-ssl
   command -v fw3
   ```

   Эта ветка не предназначена для firewall4/nftables или apk. Не подменяйте
   feeds модулей ядра пакетами от другой прошивки.

2. Подключите исходный feed v2rayA:

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

3. Установите базовые пакеты и зависимости firewall3:

   ```sh
   opkg install v2raya xray-core luci-app-v2raya
   opkg install iptables-mod-conntrack-extra iptables-mod-extra \
     iptables-mod-filter iptables-mod-tproxy kmod-ipt-nat6
   # Если нужны локальные базы правил:
   # opkg install v2fly-geoip v2fly-geosite
   ```

   Все команды должны завершиться успешно. Сейчас установлены версии из
   feed; далее обновляются v2raya и при необходимости Xray. LuCI и зависимости
   остаются из прежних feeds.

4. Скачайте **новый** installer и запустите проверку:

   ```sh
   wget -O /tmp/install-v2raya-release.sh \
     https://github.com/DragonSavA/v2raya-openwrt/releases/latest/download/install-release.sh &&
   sh /tmp/install-v2raya-release.sh --check
   ```

   `--check` скачивает необходимые IPK, проверяет хеши/метаданные и запускает
   `xray run -test`. Он не устанавливает пакеты, не запускает дополнительный
   proxy-сервис и не останавливает работающий v2rayA. При ошибке исправьте
   причину и повторите проверку. Старый installer r2 не подходит для нового
   формата manifest.

5. После успешной проверки выполните установку:

   ```sh
   sh /tmp/install-v2raya-release.sh
   opkg status v2raya xray-core
   /usr/bin/v2raya --version
   /usr/bin/xray version
   ```

   Ожидается v2raya `2.2.7.5-r3` (бинарник сообщает `2.2.7.5`) и Xray
   `26.3.27` либо сохранённое более новое рабочее ядро. После успеха оба пакета
   получают `opkg flag hold`. Если нужной архитектуры нет, скрипт честно
   сообщает об этом и оставляет установленную версию без изменений.

6. При чистой установке включите сервис:

   ```sh
   uci set v2raya.config.enabled='1'
   uci commit v2raya
   /etc/init.d/v2raya enable
   /etc/init.d/v2raya start
   ```

   Откройте LuCI `Службы → v2rayA` и WebUI `http://<IP-роутера>:2017`.

## Обновление версии из feed или прежнего форка

Для перехода с `2.2.7.4-r1` из feed либо нашего `2.2.7.5-r2` выполните
раздел «Перед обновлением», затем шаги 4–5. Повторно устанавливать feed,
LuCI и зависимости не нужно; `hold` старого r2 учитывается автоматически.
Installer сохраняет UCI, базу `/etc/v2raya`, автозапуск и состояние сервиса:
работавший перезапускается, остановленный остаётся остановленным.
Перезапуск кратковременно разрывает соединения.

Если r3 уже установлена, но Xray ещё старый, ядро всё равно обновляется.
Для переустановки v2raya той же версии из другого релиза используйте
`--reinstall`; более новый Xray при этом не заменяется старым.
Для осознанного снятия защиты от замены из feed:

```sh
opkg flag ok v2raya
opkg flag ok xray-core
```

## Проверка на GL-MT3600BE после обновления

1. Убедитесь, что сохранились аккаунт WebUI, серверы, подписки, настройки
   UCI/LuCI и привычные правила маршрутизации. Проверьте версии.
2. Проверьте по очереди прежние **Trojan, TUIC, VLESS WS+TLS**: открытие
   сайтов, длительное TCP-соединение, DNS и нужный режим прозрачного прокси.
3. Обновите подписку S-UI либо импортируйте `hysteria2://`/`hy2://` через Import.
   Для Hysteria2 поддержаны SNI, ALPN `h3`, Salamander, `mport` и
   `upmbps`/`downmbps`; пароли с URL-экранированием и IPv6 сохраняются.
   Встроенный legacy WebUI не имеет отдельной формы редактирования Hysteria2:
   добавляйте/меняйте настройки через ссылки и подписки, не через старую
   ручную форму другого протокола. Убедитесь, что узел появился в списке.
4. Подключите Hysteria2 с доверенным TLS. Проверьте HTTP/HTTPS, большой файл,
   UDP/DNS, прозрачный прокси, повторное соединение. Если включены Salamander
   или hopping, проверьте их на настоящем сервере; UDP-порты/диапазоны должны
   быть разрешены на сервере. Нативный outbound в конфигурации Xray называется
   `hysteria` с `version: 2`, а не `hysteria2`.
5. Проверьте логи и остановку/запуск сервиса:

   ```sh
   logread -e v2raya
   logread -e xray
   pidof v2raya xray
   ```

   Ошибок `unsupported link type: hysteria2`/`hy2` быть не должно. AnyTLS,
   Naive, Snell и Hysteria v1 не добавлены. `insecure=1` у Hysteria2 импортируется,
   но при подключении выдаёт явную ошибку: обновите сертификат/SNI и ссылку.
6. Перезагрузите роутер и повторите проверки выбранных узлов, DNS и LuCI.
7. Наблюдайте память 24–72 часа при обычной нагрузке, особенно при обновлении
   GeoIP/подписок и работе Hysteria2. Потребление QUIC/Xray может отличаться;
   исправление GeoIP в backend сохраняется, но нового результата по памяти
   на вашем роутере заранее не предполагаем. Если действует watchdog по
   памяти, временно отключите его для измерения.

Монитор можно скачать на роутере (следите за размером CSV на flash):

```sh
wget -O /tmp/router-memory-monitor.sh \
  https://raw.githubusercontent.com/DragonSavA/v2raya-openwrt/legacy-2.2.7.5-memfix/scripts/router-memory-monitor.sh
nohup sh /tmp/router-memory-monitor.sh 60 /root/v2raya-memory.csv \
  >/tmp/v2raya-memory-monitor.log 2>&1 &
echo $! >/tmp/v2raya-memory-monitor.pid
# Остановка: kill "$(cat /tmp/v2raya-memory-monitor.pid)"
```

## Резервная копия и откат обоих пакетов

Перед изменениями installer печатает путь:
`/root/v2raya-backups/<дата-время>-<PID>/`. В архиве сохранены старые бинарники
v2raya/Xray, UCI, база, init, старые Xray-owned файлы и metadata opkg; в
`package-status.txt` — записи **обоих** пакетов с прежними флагами.
Архив содержит приватные настройки: храните его как резервную копию аккаунтов.

При ошибке opkg, запуска бинарника/сервиса или отсутствии перезапуска прежде
работавшего Xray скрипт восстанавливает копию автоматически. Успешный старт
процессов не подтверждает доступность всех удалённых серверов. Если проблему
нашли позже, выполните ручной откат из **копии этого r3 installer**:

```sh
(
set -e
V2RAYA_BACKUP='/root/v2raya-backups/<дата-время>-<PID>'
test -s "$V2RAYA_BACKUP/files.tar.gz" &&
test -s "$V2RAYA_BACKUP/package-status.txt" || exit 1
/etc/init.d/v2raya stop
rm -f /usr/lib/opkg/info/v2raya.* /usr/lib/opkg/info/xray-core.*
tar -xzf "$V2RAYA_BACKUP/files.tar.gz" -C /
awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /^Package: (v2raya|xray-core)\n/ { print }' \
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
opkg status v2raya xray-core
/usr/bin/v2raya --version
/usr/bin/xray version
)
```

Откат возвращает и старую базу: настройки/подписки, изменённые после
обновления, потеряются. Hysteria2-объекты старый backend не понимает, поэтому
возвращать только старый бинарник без соответствующей базы не следует.
Не используйте `--force-depends`/`--force-architecture`. Для результатов
теста укажите модель, прошивку/ядро, `opkg print-architecture`, тег Release,
обе версии, режим прокси, проверенные протоколы и наблюдения по памяти.
