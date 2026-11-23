#!/usr/bin/env bash
set -euo pipefail

# Skrypt startowy Factory: cel jedynej reguły sudo Maestro
# (sudo -n -u factory /usr/local/lib/factory-serwer/start-factory.sh [<id polecenia>]).
#
# Bez argumentu: zakłada sesję tmux "factory" z powłoką w folderze laboratorium (poza trybem użytkownika z pliku
# roota /var/lib/factory-serwer/tryb i gdy laboratorium jest), inaczej w folderze domowym, gdy sesji nie ma.
# Kod 0: sesja "factory" istnieje po przebiegu. Kod 1: inne konto niż factory albo sesja nie powstała.
#
# Z jednym argumentem <id wiadomości> (wzorzec RRRRMMDD-GGMMSS-xxxx): przekazuje sesji głównej Factory
# wiadomość Maestro z pliku /var/lib/factory-serwer/skrzynka/<id>.json (folder i zwykły tekst).
# Sprawdzenie (pola, folder, właściciel i prawa pliku) robi skrzynka.py sprawdz, zanim cokolwiek ruszy;
# turę claude -p w folderze wiadomości uruchamia skrzynka.py wykonaj w usłudze systemd-run --user konta
# factory i skrypt wraca od razu. Koniec pracy to zawsze plik /var/lib/factory-serwer/wyniki/<id>.json.
# Kod 0: usługa wystartowała. Kod 1: inne konto niż factory albo usługa nie wystartowała.
# Kod 2: zły identyfikator, odmowa skrzynka.py sprawdz albo więcej niż jeden argument.

# poprawny_id <id>: identyfikator polecenia według stałego wzorca, w locale C (zakresy liter bez wyjątków).
poprawny_id() {
  local LC_ALL=C
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$ ]]
}

# folder_sesji <plik trybu> <laboratorium> <dom>: folder sesji tmux. Laboratorium, gdy treść pliku trybu roota to nie
# uzytkownik (autor, brak pliku albo błąd odczytu) i folder laboratorium jest; inaczej folder domowy konta.
folder_sesji() {
  local tryb
  tryb=$(cat -- "$1" 2> /dev/null) || tryb=""
  if [ "$tryb" != uzytkownik ] && [ -d "$2" ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$3"
  fi
}

if [ "$(id -un)" != "factory" ]; then
  echo "start-factory.sh: uruchom jako konto factory (sudo -n -u factory $0)." >&2
  exit 1
fi

if [ "$#" -gt 1 ]; then
  echo "start-factory.sh: skrypt przyjmuje najwyżej jeden argument: identyfikator polecenia ze skrzynki." >&2
  exit 2
fi

# sudo resetuje środowisko, więc skrypt ustawia je sam.
export HOME=/home/factory
export PATH="/home/factory/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

if [ "$#" -eq 1 ]; then
  if ! poprawny_id "$1"; then
    echo "start-factory.sh: identyfikator polecenia nie pasuje do wzorca RRRRMMDD-GGMMSS-xxxx." >&2
    exit 2
  fi
  # Odmowa przed uruchomieniem czegokolwiek: zły format, folder spoza listy, dowiązanie, pusty tekst, zły
  # właściciel albo prawa pliku.
  if ! /usr/bin/python3 /usr/local/lib/factory-serwer/skrzynka.py sprawdz "$1"; then
    exit 2
  fi
  # Praca w menedżerze użytkownika factory, a nie w grupie procesów maestro.service, z której przychodzi
  # sudo: restart usługi Maestro jej nie przerywa. Treść polecenia nie przechodzi przez powłokę.
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  if systemd-run --user --quiet --collect --unit="factory-polecenie-$1" \
    /usr/bin/python3 /usr/local/lib/factory-serwer/skrzynka.py wykonaj "$1"; then
    exit 0
  fi
  echo "start-factory.sh: usługa factory-polecenie-$1 nie wystartowała." >&2
  exit 1
fi

FOLDER=$(folder_sesji /var/lib/factory-serwer/tryb /home/factory/fabryka "$HOME")
cd "$FOLDER"

if ! tmux has-session -t factory 2>/dev/null; then
  # Serwer tmux startuje w menedżerze użytkownika factory (linger włącza instalator), a nie w grupie
  # procesów usługi Maestro, z której przychodzi sudo: restart maestro.service go nie zabija.
  # Usługa przejściowa, nie --scope: konto nie może przenieść procesu z grupy usługi systemowej.
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  systemd-run --user --quiet --collect -p Type=forking \
    /usr/bin/tmux new-session -d -s factory -c "$FOLDER"
fi

if tmux has-session -t factory 2>/dev/null; then
  exit 0
fi
echo "start-factory.sh: sesja tmux factory nie powstała." >&2
exit 1
