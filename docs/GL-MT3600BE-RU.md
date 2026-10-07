# v2rayA legacy memory fix для GL-MT3600BE

> Архивная памятка для первоначального **r2** memory backport. Для новой r3,
> Xray 26.3.27, Hysteria2 и отката **обоих** пакетов используйте
> [актуальную инструкцию INSTALL-RU.md](INSTALL-RU.md). Не применяйте ниже
> описанный откат только v2raya к установке r3.


Этот вариант предназначен прежде всего для:

- GL.iNet GL-MT3600BE;
- CPU/ABI: `aarch64`, OpenWrt package architecture `aarch64_cortex-a53`;
- фирменной прошивки на базе OpenWrt 21.02-SNAPSHOT;
- обновления установленного `v2raya 2.2.7.4-r1`.

Пакет сохраняет существующие UCI, procd/init, LuCI и внешний `xray-core`.
Формат базы v2rayA не меняется.

## Что изменено

1. Базовая версия обновлена до v2rayA 2.2.7.5. В ней уже исправлена
   ошибка LRU-кэша из upstream commit `c3752dd6`.
2. Backport из upstream PR #1933 разбирает только запрошенную запись
   `geoip.dat`, не разворачивая весь файл в памяти, и кэширует результат.
3. Версия OpenWrt-пакета: `2.2.7.5-r2`.

## Сборка

После push в `legacy-2.2.7.5-memfix` workflow
`Build and release legacy v2rayA` собирает девять архитектур и публикует
Releases, если все сборки и проверки успешны. Можно также запустить его
вручную из Actions. Пакет вашего устройства — `aarch64_cortex-a53`.

При установленном Go 1.21.13 тот же пакет можно собрать локально:

```sh
bash scripts/build-standalone-ipk.sh
```

Workflow напрямую собирает статический ARM64-бинарник через Go 1.21 и
формирует совместимый с opkg `.ipk`. SDK другой версии OpenWrt при этом
не используется. v2rayA собирается с `CGO_ENABLED=0`; пакет не получает
зависимостей от firewall4 или библиотек новой версии OpenWrt.

## Подготовка роутера

Убедитесь, что архитектура и исходная версия совпадают:

```sh
uname -m
opkg print-architecture
opkg status v2raya
```

До обновления остановите пользовательский watchdog, который автоматически
перезапускает v2rayA при нехватке памяти. Иначе результаты проверки будут
недостоверны.

Сохраните старый бинарник, конфигурацию и базу. Каталог находится на
постоянном overlay, но резервную копию после создания желательно скопировать
с роутера на ПК:

```sh
mkdir -p /root/v2raya-rollback-2.2.7.4
cp -p /usr/bin/v2raya /root/v2raya-rollback-2.2.7.4/v2raya
cp -p /etc/init.d/v2raya /root/v2raya-rollback-2.2.7.4/v2raya.init
opkg status v2raya > /root/v2raya-rollback-2.2.7.4/opkg-status.txt

/etc/init.d/v2raya stop
tar -czf /root/v2raya-rollback-2.2.7.4/config-and-db.tar.gz \
    /etc/config/v2raya /etc/v2raya
```

## Установка

Первоначальный IPK уже проверен пользователем на этом роутере. Для
установки опубликованного релиза файлы с ПК передавать не требуется:

```sh
wget -O /tmp/install-v2raya-release.sh \
    https://github.com/DragonSavA/v2raya-openwrt/releases/latest/download/install-release.sh &&
sh /tmp/install-v2raya-release.sh
```

Если `2.2.7.5-r2` уже установлена, скрипт не повторяет обновление.
Для явной переустановки используйте `--reinstall`. Скрипт сам сохраняет
резервную копию и прежнее состояние сервиса; подробности и откат описаны
в [INSTALL-RU.md](INSTALL-RU.md).

Ручная установка локально собранного `.ipk` остаётся возможной:

```sh
opkg install /tmp/v2raya_2.2.7.5-r2_aarch64_cortex-a53.ipk
/etc/init.d/v2raya start

opkg status v2raya
/usr/bin/v2raya --version
logread -e v2raya
```

Не используйте `--force-depends` или `--force-architecture`. Если обычная
установка отклоняет пакет, остановитесь и сохраните полный текст ошибки.

## Функциональная проверка

После обновления проверьте:

1. Открывается страница LuCI `Службы → v2rayA`.
2. WebUI на порту 2017 принимает прежнюю учётную запись.
3. Список серверов и подписки сохранились.
4. Xray запускается и останавливается из v2rayA.
5. Работают обычный proxy и используемый режим прозрачного прокси.
6. DNS работает как при включённом, так и при выключенном прокси.
7. После остановки v2rayA не остаётся процесс Xray, слушающий служебный порт.

## Наблюдение за памятью

Скачайте монитор прямо с роутера и запустите:

```sh
wget -O /tmp/router-memory-monitor.sh \
    https://raw.githubusercontent.com/DragonSavA/v2raya-openwrt/legacy-2.2.7.5-memfix/scripts/router-memory-monitor.sh
nohup sh /tmp/router-memory-monitor.sh 60 /root/v2raya-memory.csv \
    >/tmp/v2raya-memory-monitor.log 2>&1 &
echo $! >/tmp/v2raya-memory-monitor.pid
```

Желательно собрать:

- несколько часов baseline до обновления;
- не менее 24 часов после обновления;
- предпочтительно 72 часа при обычной нагрузке.

Проверка OOM:

```sh
logread | grep -i -E 'out of memory|oom|killed process'
```

Остановка монитора:

```sh
kill "$(cat /tmp/v2raya-memory-monitor.pid)"
```

## Быстрый откат

Если новый процесс не запускается или нарушает работу сети:

```sh
/etc/init.d/v2raya stop
cp -p /root/v2raya-rollback-2.2.7.4/v2raya /usr/bin/v2raya
tar -xzf /root/v2raya-rollback-2.2.7.4/config-and-db.tar.gz -C /
/etc/init.d/v2raya start
```

Это аварийный откат бинарника; запись opkg при этом всё ещё показывает
2.2.7.5-r2. Для полного отката затем установите сохранённый официальный
`.ipk` 2.2.7.4-r1:

```sh
opkg install --force-downgrade /tmp/v2raya_2.2.7.4-r1_aarch64_cortex-a53.ipk
```

Так как формат базы не менялся, её конвертация в обе стороны не требуется.
