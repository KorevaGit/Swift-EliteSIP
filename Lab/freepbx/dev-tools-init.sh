#!/bin/bash
# EliteSIP: тестовые номера для отладки звука и TLS+SRTP профиль.
#
# До 31 июля 2026 это делали два отдельных стенда: голый Asterisk 13
# (`elitesip-lab13`) и Asterisk 16 (`elitesip-lab`) со своим ручным
# extensions.conf. Оба убраны — FreePBX стал единственным стендом, и для него
# и работы клиента, и обучения. Номера ниже перенесены оттуда почти без
# изменений; что не перенесено и почему — см. Lab/README.md.
set -euo pipefail

ASTETC=/etc/asterisk

# --- Тестовые номера для звука и перевода ------------------------------------
#
# Экземпляр [from-internal-custom] уже объявлен в extensions_m1_6.conf (номер
# 600). Asterisk сливает одноимённые контексты из разных #include — второе
# объявление здесь не перетирает первое, а дополняет его.
cat > "$ASTETC/extensions_dev.conf" <<'EXTENSIONS'
[from-internal-custom]

; 650 — эхо. Основная цель для проверки звука: слышно себя => путь RTP
; туда-обратно живой. Не 600: там уже занят записываемый демо-звонок M1.6,
; который сам кладёт трубку через секунду и для растянутой проверки не годится.
exten => 650,1,NoOp(EliteSIP dev: echo test)
 same => n,Answer()
 same => n,Wait(1)
 same => n,Echo()
 same => n,Hangup()

; 601 — односторонний звук. Отделяет "не работает приём" от "не работает передачу".
exten => 601,1,NoOp(EliteSIP dev: playback test)
 same => n,Answer()
 same => n,Wait(1)
 same => n,Playback(hello-world)
 same => n,Playback(demo-congrats)
 same => n,Hangup()

; 602 — тон 1004 Гц. Для замера искажений и джиттер-буфера на слух.
exten => 602,1,NoOp(EliteSIP dev: milliwatt tone)
 same => n,Answer()
 same => n,Milliwatt()

; 603 — говорит обратно то, что ввели DTMF. Проверка RFC 2833.
exten => 603,1,NoOp(EliteSIP dev: DTMF readback)
 same => n,Answer()
 same => n,Wait(1)
 same => n,Read(DIGITS,beep,10,,1,10)
 same => n,SayDigits(${DIGITS})
 same => n,Hangup()

; 700/701/702 — цели для проверки перевода. Дозвон обратно на зарегистрированный
; softphone для этого не годится: на Docker Desktop внешний порт клиента
; меняется чуть ли не на каждой датаграмме, и INVITE от Asterisk уходит на
; устаревшую привязку. Local-канал даёт настоящий мост без этой проблемы, а
; растянутые во времени 650/602/22998 (а не 600, который сам вешает трубку)
; оставляют время на сам перевод.
exten => 700,1,NoOp(EliteSIP dev: bridged echo)
 same => n,Dial(Local/650@from-internal-custom,30)
 same => n,Hangup()

exten => 701,1,NoOp(EliteSIP dev: bridged milliwatt)
 same => n,Dial(Local/602@from-internal-custom,30)
 same => n,Hangup()

exten => 702,1,NoOp(EliteSIP dev: bridged playback)
 same => n,Dial(Local/22998@from-internal-custom,30)
 same => n,Hangup()

; 8000 — конференция по умолчанию, _80XX — комната с номером из последних двух
; цифр. default_bridge и default_user уже объявлены самим FreePBX
; (confbridge_additional.conf) — своего профиля заводить не нужно.
exten => 8000,1,NoOp(EliteSIP dev: ConfBridge default room)
 same => n,Answer()
 same => n,ConfBridge(1,default_bridge,default_user)
 same => n,Hangup()

exten => _80XX,1,NoOp(EliteSIP dev: ConfBridge room ${EXTEN:2})
 same => n,Answer()
 same => n,ConfBridge(${EXTEN:2},default_bridge,default_user)
 same => n,Hangup()

; 22998 — заглушка «горячей раздачи». Отвечает и молчит ~60 с, чтобы было куда
; переводить в проверках M5, и чтобы 702 успевал остаться в мосту.
exten => 22998,1,NoOp(EliteSIP dev: hot queue stub)
 same => n,Answer()
 same => n,Wait(1)
 same => n,Playback(demo-thanks)
 same => n,Wait(60)
 same => n,Hangup()

; --- Конференция по *3 -------------------------------------------------------
;
; Перехватывает обычный набор номера для 100–103 и 200 (обычно это
; ext-local/Macro(exten-vm,…) из extensions_additional.conf) и добавляет
; dynamic feature conf_pull (см. features_applicationmap_dev.conf) плюс флаг
; `g` у Dial. [from-internal-custom] включается в from-internal-xfer раньше,
; чем ext-local (тот приезжает из from-internal-additional — на 30 include
; позже), и потому наша запись обгоняет штатную. Проверено `dialplan show
; 100@from-internal`: без этого блока штатная запись, с ним — наша.
;
; Расплата известная и принятая: голосовая почта, DND и переадресация из
; ext-local для 100–103 здесь не работают — это тот же обмен, что был в
; убранной лабе на голом Asterisk, а не новая потеря. Запись разговора — нет,
; её сюда завели явно: Gosub(sub-record-check,…) — тот же вызов, которым
; пользуется сам FreePBX (see extensions_additional.conf, _XXX,n), и без него
; автоматическая запись для этих же номеров пропала бы вместе с конференцией.
;
; GotoIf/ConfBridge после Dial — часть исходного прототипа, и она НЕ
; срабатывает: Dial(...,g) должен был возвращать управление, когда собеседник
; уходит в конференцию, но проверка 31 июля показала, что в бридинге
; Asterisk 13 (пост-12) это не так — канал собеседника остаётся формальным
; членом исходного simple_bridge (`bridge show` держит Num-Channels: 2), и
; Dial не возвращается ни через 10 секунд, ни через 37. Пробовал чинить через
; ActivateOn=peer,Gosub,… с ChannelRedirect второго канала — сработало один
; раз из трёх попыток и статистически ненадёжно; прямой `ConfBridge` в
; applicationmap отработал стабильно во всех проверках. Оставляю строку ниже
; недостижимой, а не удаляю: без нового способа дозвать оператора это честная
; фиксация того, что задумано, но не получилось, а не работающий код.
exten => _10X,1,NoOp(EliteSIP dev: dial ${EXTEN} с поддержкой конференции)
 same => n,Gosub(sub-record-check,s,1(exten,${EXTEN},))
 same => n,Set(__CONFROOM=conf-${CALLERID(num)})
 same => n,Set(__DYNAMIC_FEATURES=conf_pull)
 same => n,Dial(SIP/${EXTEN},30,gtT)
 same => n,GotoIf($[${CONFBRIDGE_INFO(parties,${CONFROOM})} > 0]?join:done)
 same => n(join),NoOp(Собеседник ушёл в конференцию ${CONFROOM}, заходим следом)
 same => n,ConfBridge(${CONFROOM},default_bridge,admin_user)
 same => n(done),Hangup()

exten => 200,1,NoOp(EliteSIP dev: dial 200 (TLS) с поддержкой конференции)
 same => n,Gosub(sub-record-check,s,1(exten,200,))
 same => n,Set(__CONFROOM=conf-${CALLERID(num)})
 same => n,Set(__DYNAMIC_FEATURES=conf_pull)
 same => n,Dial(SIP/200,30,gtT)
 same => n,GotoIf($[${CONFBRIDGE_INFO(parties,${CONFROOM})} > 0]?join:done)
 same => n(join),ConfBridge(${CONFROOM},default_bridge,admin_user)
 same => n(done),Hangup()
EXTENSIONS

# Dynamic feature conf_pull. Отдельный файл, не sip_general_dev.conf: это
# features.conf, у него свой include (features_applicationmap_custom.conf).
#
# ActivateOn=peer — выполняется на канале СОБЕСЕДНИКА: он уходит в ConfBridge
# в комнату ${CONFROOM}, унаследованную от канала звонящего через __ в
# extensions_dev.conf. Это подтверждено стабильно на живом стенде — 31 июля
# 2026, десятки последовательных вызовов без единого срыва. Дозаход самого
# оператора в ту же комнату (флаг g у Dial выше) не работает — см. комментарий
# там же; это открытая проблема, а не решённая.
cat > "$ASTETC/features_applicationmap_dev.conf" <<'APPMAP'
conf_pull => *3,peer,ConfBridge,${CONFROOM}
APPMAP

touch "$ASTETC/features_applicationmap_custom.conf"
chown asterisk:asterisk "$ASTETC/features_applicationmap_dev.conf" "$ASTETC/features_applicationmap_custom.conf"
if ! grep -Fqx '#include features_applicationmap_dev.conf' "$ASTETC/features_applicationmap_custom.conf"; then
  printf '\n; EliteSIP: конференция по *3\n#include features_applicationmap_dev.conf\n' \
    >> "$ASTETC/features_applicationmap_custom.conf"
fi

touch "$ASTETC/extensions_custom.conf"
chown asterisk:asterisk "$ASTETC/extensions_dev.conf" "$ASTETC/extensions_custom.conf"
if ! grep -Fqx '#include extensions_dev.conf' "$ASTETC/extensions_custom.conf"; then
  printf '\n; EliteSIP: тестовые номера для звука и перевода\n#include extensions_dev.conf\n' \
    >> "$ASTETC/extensions_custom.conf"
fi

# --- TLS + SRTP: профиль M2b -------------------------------------------------
#
# Боевой сервер TLS не использует (сверено 31 июля 2026), но клиент этот
# профиль поддерживает, и проверять его нужно на чём-то живом. Раньше это был
# отдельный пир на голом Asterisk; здесь — свой пир поверх FreePBX, сознательно
# мимо GUI: FreePBX 15 сам TLS-пиров не создаёт, а заводить их через веб
# означало бы держать секрет в базе данных модуля, которым не пользуемся.
cat > "$ASTETC/sip_general_dev.conf" <<'GENERAL'
tlsenable=yes
tlsbindaddr=0.0.0.0:5061
; НЕ /etc/asterisk/keys: тот каталог занят собственным PKI-модулем FreePBX
; (PKCS.class.php) и не годится для стороннего сертификата.
tlscertfile=/etc/asterisk/elitesip-keys/asterisk.pem
tlsprivatekey=/etc/asterisk/elitesip-keys/asterisk.pem
tlscipher=ALL
tlsdontverifyserver=yes
GENERAL

touch "$ASTETC/sip_general_custom.conf"
chown asterisk:asterisk "$ASTETC/sip_general_dev.conf" "$ASTETC/sip_general_custom.conf"
if ! grep -Fqx '#include sip_general_dev.conf' "$ASTETC/sip_general_custom.conf"; then
  printf '\n; EliteSIP: TLS для профиля M2b\n#include sip_general_dev.conf\n' \
    >> "$ASTETC/sip_general_custom.conf"
fi

cat > "$ASTETC/sip_dev.conf" <<'PEER'
; encryption=yes в chan_sip означает СТРОГО шифрованно: если клиент не умеет
; SRTP, звонок отвалится, промежуточного "optimistic" здесь нет.
[200]
type=friend
host=dynamic
context=from-internal
secret=elite200
callerid="Agent 200 secure" <200>
disallow=all
allow=ulaw
allow=alaw
allow=gsm
allow=g726
allow=g722
dtmfmode=rfc2833
directmedia=no
nat=force_rport,comedia
transport=tls
encryption=yes
qualify=yes
PEER

touch "$ASTETC/sip_custom.conf"
chown asterisk:asterisk "$ASTETC/sip_dev.conf" "$ASTETC/sip_custom.conf"
if ! grep -Fqx '#include sip_dev.conf' "$ASTETC/sip_custom.conf"; then
  printf '\n; EliteSIP: TLS-пир для профиля M2b\n#include sip_dev.conf\n' \
    >> "$ASTETC/sip_custom.conf"
fi

asterisk -rx 'dialplan reload' >/dev/null
asterisk -rx 'sip reload' >/dev/null
asterisk -rx 'module reload features' >/dev/null
