#!/usr/bin/env bash
#
# Prueba de humo de la rama Linux de install.sh, para correr DENTRO del
# contenedor de test/Dockerfile:
#
#   docker build -t twd-mods-test test/
#   docker run --rm -v "$PWD:/work:ro" -v "$PWD/downloads:/dl:ro" \
#       twd-mods-test bash /work/test/linux-smoke.sh
#
# /dl va de solo lectura para que una prueba a medias no estropee la única
# descarga del AppImage; todo el trabajo pasa por copias en /tmp.
#
# Lo que NO cubre: arrancar el juego. Eso necesita OpenGL y una pantalla. El
# riesgo que queda es bajo porque el Lua que se ejecuta es el mismo .love ya
# verificado en macOS, pero los asertos de aquí están elegidos para tapar lo
# que un contenedor sin GUI sí puede detectar — en particular que el
# ida-y-vuelta por squashfs no se coma permisos ni archivos del AppDir, que
# rompería el juego de una forma que ninguna comprobación de ZIP vería.

set -uo pipefail

REPO=/work
SRC="$(find /dl -maxdepth 1 -name '*.AppImage' | head -1)"
[ -n "$SRC" ] || { echo "error: no hay ningún .AppImage en /dl" >&2; exit 1; }

WORK=/tmp/smoke
PRISTINE=/tmp/pristine.AppImage
IMG="$WORK/$(basename "$SRC")"

rm -rf "$WORK"; mkdir -p "$WORK"
cp "$SRC" "$PRISTINE"
cp "$SRC" "$IMG"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32m OK \033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFALLO\033[0m %s\n' "$1"; }
# El comando va guardado tras el `if` para que set -e no aborte la tanda: se
# quieren todos los asertos, no solo hasta el primero que falle.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# Hace falta una variante negada: pasarle `!` a check lo trataría como nombre
# de comando, no como la negación del shell.
check_not() { local d="$1"; shift; if ! "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# Offset del squashfs, recalculado aquí y no tomado de install.sh: si el
# instalador se equivocara al leer las cabeceras ELF, esta prueba tiene que
# discrepar en vez de repetir el mismo error.
offset_of() {
    python3 - "$1" <<'PY'
import struct, sys
h = open(sys.argv[1], 'rb').read(64)
assert h[:4] == b'\x7fELF' and h[8:11] == b'AI\x02', "no es un AppImage type 2"
shoff,   = struct.unpack_from('<Q', h, 0x28)
shentsz, = struct.unpack_from('<H', h, 0x3a)
shnum,   = struct.unpack_from('<H', h, 0x3c)
print(shoff + shentsz * shnum)
PY
}

has_squashfs() {
    local off
    off="$(offset_of "$1")" || return 1
    [ "$(head -c $(( off + 4 )) "$1" | tail -c 4)" = "hsqs" ]
}

# Extrae AppDir + .love de un AppImage a $2. Devuelve la ruta del .love.
explode() {
    local img="$1" dest="$2" off love
    rm -rf "$dest"; mkdir -p "$dest"
    off="$(offset_of "$img")" || return 1
    unsquashfs -no-progress -o "$off" -d "$dest/AppDir" "$img" >/dev/null 2>&1 || return 1
    love="$(find "$dest/AppDir" -maxdepth 2 -name '*.love' -type f | head -1)"
    [ -n "$love" ] || return 1
    unzip -q -o "$love" -d "$dest/love" || return 1
    printf '%s\n' "$love"
}

echo
echo "=== 1. Instalación ==========================================="
bash "$REPO/install.sh" "$IMG" || { echo "error: install.sh falló" >&2; exit 1; }
check "se creó el backup .orig"                    test -f "$IMG.orig"
check "el .orig es la descarga original byte a byte" cmp -s "$IMG.orig" "$PRISTINE"
check_not "el AppImage parcheado cambió"           cmp -s "$IMG" "$PRISTINE"

echo
echo "=== 2. Idempotencia =========================================="
cp "$IMG" /tmp/first.AppImage
bash "$REPO/install.sh" "$IMG" >/dev/null || { echo "error: reinstalar falló" >&2; exit 1; }
check "reinstalar da el mismo AppImage byte a byte" cmp -s "$IMG" /tmp/first.AppImage
check "el .orig sigue siendo el original"           cmp -s "$IMG.orig" "$PRISTINE"

echo
echo "=== 3. Contenido del .love ==================================="
LOVE="$(explode "$IMG" /tmp/patched)"
if [ -n "$LOVE" ]; then
    ok "se extrae el AppDir y el .love (${LOVE#/tmp/patched/AppDir/})"

    # Un aserto por cada .lua de mod/, en vez de uno con el nombre escrito a
    # mano: añadir un mod es soltar un archivo ahí, y esta prueba tiene que
    # cubrirlo sin que haya que acordarse de volver aquí.
    for src in "$REPO"/mod/*.lua; do
        name=$(basename "$src")
        check "mods/$name está y es idéntico al del repo" \
            cmp -s "/tmp/patched/love/mods/$name" "$src"
    done

    # Dos cargadores serían el síntoma de haber parcheado sobre lo ya
    # parcheado en vez de sobre el backup.
    n=$(grep -c -- '-- twd-mods loader' /tmp/patched/love/conf.lua || true)
    [ "$n" = 1 ] && ok "el cargador aparece exactamente una vez en conf.lua" \
                 || bad "el cargador aparece $n veces en conf.lua (se esperaba 1)"

    check "el .love es un ZIP íntegro" unzip -t "$LOVE"

    # LÖVE va sobre LuaJIT: compilar cada archivo descarta que el apéndice del
    # cargador haya dejado conf.lua sintácticamente roto.
    broken=""
    while IFS= read -r f; do
        luajit -bl "$f" >/dev/null 2>&1 || broken="$broken $f"
    done < <(find /tmp/patched/love -name '*.lua')
    [ -z "$broken" ] && ok "todos los .lua compilan con luajit" \
                     || bad "no compilan:$broken"
else
    bad "no se pudo extraer el AppImage parcheado"
fi

echo
echo "=== 4. El AppImage sigue siendo un AppImage ==================="
check "sigue siendo ejecutable (bit +x)"      test -x "$IMG"
check "sigue teniendo el magic AI\\x02"        offset_of    "$IMG"
check "el offset apunta a un squashfs (hsqs)" has_squashfs "$IMG"

# Lo que un contenedor sin GUI sí puede pillar: que el ida-y-vuelta por
# squashfs no haya perdido archivos ni el bit de ejecución del intérprete. Un
# bin/love sin +x rompería el juego sin que ninguna comprobación del ZIP se
# entere.
explode "$PRISTINE" /tmp/orig >/dev/null
( cd /tmp/orig/AppDir  && find . | sort ) > /tmp/list-orig
( cd /tmp/patched/AppDir && find . | sort ) > /tmp/list-patched
check "el AppDir tiene exactamente los mismos archivos" \
    cmp -s /tmp/list-orig /tmp/list-patched
check "bin/love conserva el bit de ejecución" test -x /tmp/patched/AppDir/bin/love

perms_orig=$(cd /tmp/orig/AppDir    && find . -printf '%m %p\n' | sort)
perms_new=$(cd /tmp/patched/AppDir  && find . -printf '%m %p\n' | sort)
[ "$perms_orig" = "$perms_new" ] && ok "todos los permisos del AppDir se conservan" \
                                 || bad "cambiaron permisos dentro del AppDir"

echo
echo "=== 5. Desinstalación ========================================"
bash "$REPO/uninstall.sh" "$IMG" || { echo "error: uninstall.sh falló" >&2; exit 1; }
check "el AppImage vuelve a ser la descarga original byte a byte" cmp -s "$IMG" "$PRISTINE"
check "el .orig se borró"                                         test ! -f "$IMG.orig"
check "sigue siendo ejecutable tras desinstalar"                  test -x "$IMG"

echo
echo "=== AppRun (informativo: decide la ruta de guardado) =========="
sed -n '1,40p' /tmp/orig/AppDir/AppRun

echo
printf '=== Resultado: %d OK, %d fallos ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
