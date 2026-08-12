#!/usr/bin/env bash
#
# Instala los mods de TWD sobre una copia local del juego.
#
#   ./install.sh [ruta/al/juego]
#
#   macOS: la ruta es un bundle .app      (por defecto /Applications/TWD.app)
#   Linux: la ruta es un AppImage         (se busca en las rutas habituales)
#
# El parche se construye SIEMPRE a partir de un backup del original, así que
# reinstalar sobre un juego ya parcheado es seguro y sirve para actualizar el
# mod.
#
# Por qué se toca conf.lua y no main.lua: el juego se autoactualiza. conf.lua
# monta `actualizacion.love` (en el directorio de guardado) DELANTE del paquete
# del juego, así que main.lua y todo src/ salen de la actualización, no del
# paquete instalado. conf.lua es el único archivo que se lee antes de ese
# montaje y por tanto el único que una actualización no puede reemplazar: es el
# sitio donde un mod sobrevive a las actualizaciones del juego.
#
# El mod es el mismo en los dos sistemas y el .love también: lo único que
# cambia es el envoltorio (bundle .app frente a AppImage). De ahí la forma de
# este script: localizar y desenvolver por sistema, parchear en común,
# reenvolver por sistema.

set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mod"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$MOD_DIR" ] || die "falta el directorio mod/ junto a este script"
command -v zip   >/dev/null || die "hace falta 'zip'"
command -v unzip >/dev/null || die "hace falta 'unzip'"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Cirugía sobre el .love (común a los dos sistemas) --------------------

# El cargador, al final de conf.lua. Envuelve `love.run` (definida por el boot
# de LÖVE antes de leer conf.lua, y que el juego no redefine): así el require
# ocurre cuando main.lua ya está cargado y `require("src.game")` devuelve el
# módulo del paquete en uso. Recorre mods/ en vez de nombrar los archivos, para
# que añadir un mod sea soltar un .lua. Cada uno va en pcall: un mod roto
# imprime el error y el juego sigue.
#
# Vive en una función y no duplicado en cada rama a propósito: es la ÚNICA
# modificación al código del juego, y tenerlo en dos sitios sería tenerlo en
# dos versiones en cuanto se toque una.
append_loader() {
    cat >> "$1" <<'LUA'

-- twd-mods loader ---------------------------------------------------------
-- Añadido por twd-mods. Borrar este bloque desactiva los mods.
if love.run then
    local __twdRun = love.run
    love.run = function(...)
        local ok, items = pcall(love.filesystem.getDirectoryItems, "mods")
        if ok and type(items) == "table" then
            table.sort(items)
            for _, item in ipairs(items) do
                local name = item:match("^(.+)%.lua$")
                if name then
                    local done, err = pcall(require, "mods." .. name)
                    if not done then print("[twd-mods] " .. tostring(err)) end
                end
            end
        end
        return __twdRun(...)
    end
end
LUA
}

# $1 = .love limpio (origen), $2 = .love parcheado (destino).
#
# El origen es siempre un original sin tocar, nunca lo ya instalado: eso hace
# que reinstalar sea idempotente y que actualizar el mod no acumule capas de
# cargador.
patch_love() {
    local src="$1" out="$2" work="$TMP/love"

    rm -rf "$work"
    unzip -q "$src" -d "$work"
    [ -f "$work/conf.lua" ] || die "el .love no tiene conf.lua en la raíz"

    mkdir -p "$work/mods"
    cp "$MOD_DIR"/*.lua "$work/mods/"
    echo "mods    → $(cd "$MOD_DIR" && ls *.lua | tr '\n' ' ')"

    append_loader "$work/conf.lua"
    echo "loader  → añadido a conf.lua"

    # -X evita metadatos extra del sistema dentro del ZIP.
    ( cd "$work" && zip -q -r -X "$TMP/patched.love" . -x '.*' '__MACOSX/*' )
    cp "$TMP/patched.love" "$out"
}

# --- Lectura de un AppImage ----------------------------------------------

# Entero little-endian de $3 bytes en el offset $2 del archivo $1. Con od de
# coreutils, que está en cualquier sistema; se evita a propósito depender de
# python3, que un Linux mínimo puede no traer.
#
# Se compone byte a byte en vez de pedirle a od el entero entero (`-tu8`)
# porque los tipos multibyte de od no se portan igual: el od de macOS devuelve
# -64 donde el valor real es 191680. Byte a byte no hay ambigüedad de tamaño ni
# de signo, y el orden little-endian queda explícito.
le_int() {
    local val=0 pos=0 b
    for b in $(od -An -tu1 -j"$2" -N"$3" "$1"); do
        val=$(( val + b * (1 << pos) ))
        pos=$(( pos + 8 ))
    done
    printf '%s\n' "$val"
}

# Offset donde empieza el squashfs de un AppImage type 2: justo detrás de la
# tabla de secciones del ELF. Se calcula en vez de codificarlo, y así no hay
# que ejecutar el AppImage (`--appimage-offset`), lo que además permite
# inspeccionarlo desde otro sistema y no depende de que sea esta build exacta.
appimage_offset() {
    local f="$1" magic shoff shentsize shnum off

    magic="$(head -c 11 "$f" | od -An -c | tr -d ' \n')"
    case "$magic" in
        '177ELF'*'AI002') : ;;
        *) die "$f no parece un AppImage type 2 (ELF + magic AI\\x02)" ;;
    esac

    shoff="$(le_int "$f" 40 8)"      # e_shoff
    shentsize="$(le_int "$f" 58 2)"  # e_shentsize
    shnum="$(le_int "$f" 60 2)"      # e_shnum
    off=$(( shoff + shentsize * shnum ))

    # Comprobación barata que evita destrozar el archivo si el cálculo falla:
    # en ese offset tiene que estar el magic del squashfs.
    [ "$(head -c $(( off + 4 )) "$f" | tail -c 4)" = "hsqs" ] \
        || die "el offset calculado ($off) no apunta a un squashfs"

    printf '%s\n' "$off"
}

# --- macOS ----------------------------------------------------------------

install_macos() {
    local app="${1:-/Applications/TWD.app}"
    local res="$app/Contents/Resources"
    local love="$res/twd.love" orig="$res/twd.love.orig"

    [ -d "$app" ]  || die "no existe $app (pásalo como argumento si está en otro sitio)"
    [ -f "$love" ] || die "no se encuentra $love; ¿es un bundle de LÖVE?"

    # Backup, solo si no existe ya: si el juego está parcheado, twd.love ya no
    # es el original y sobrescribir el .orig perdería la copia limpia para
    # siempre.
    if [ ! -f "$orig" ]; then
        cp "$love" "$orig"
        echo "backup  → $orig"
    else
        echo "backup  → ya existía, se reutiliza"
    fi

    patch_love "$orig" "$love"
    echo "empaque → $love"

    # Refirma: tocar Resources/ invalida _CodeSignature y macOS se niega a
    # abrir la app. La firma ad-hoc lo resuelve.
    if command -v codesign >/dev/null; then
        codesign --force --deep --sign - "$app" >/dev/null 2>&1 \
            && echo "firma   → ad-hoc aplicada" \
            || echo "firma   → AVISO: codesign falló; puede que la app no abra"
    fi

    printf '\nListo. En partida, F8 suma 5 vidas y F7 suma 5000 de oro (sin límite de usos).\n'
    printf 'Para revertir: ./uninstall.sh "%s"\n' "$app"
}

# --- Linux ----------------------------------------------------------------

# En Linux no hay una ruta canónica: un AppImage vive donde el usuario lo dejó.
# Se buscan los sitios habituales y, si no aparece, se pide explícitamente.
# El nombre se busca por los dos productos porque la build de Linux se
# distribuye como Chibola y la de macOS como TWD.
find_appimage() {
    local dir cand
    for dir in "$HOME/Applications" "$HOME/.local/bin" "$HOME/bin" \
               "$HOME/Downloads" "$HOME/Descargas" /opt /usr/local/bin; do
        [ -d "$dir" ] || continue
        for cand in "$dir"/Chibola*.AppImage "$dir"/TWD*.AppImage; do
            [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
        done
    done
    return 1
}

install_linux() {
    local img="${1:-}" orig off comp bs appdir love runtime flag
    local -a sqflags

    command -v unsquashfs >/dev/null || die "hace falta 'unsquashfs' (paquete squashfs-tools)"
    command -v mksquashfs >/dev/null || die "hace falta 'mksquashfs' (paquete squashfs-tools)"

    if [ -z "$img" ]; then
        img="$(find_appimage)" \
            || die "no encuentro el AppImage; pásalo como argumento: ./install.sh ruta/al/juego.AppImage"
        echo "juego   → $img"
    fi
    [ -f "$img" ] || die "no existe $img"
    [ -w "$img" ] && [ -w "$(dirname "$img")" ] \
        || die "sin permiso de escritura en $img (prueba con sudo, o copia el AppImage a tu \$HOME)"

    orig="$img.orig"

    # Igual que en macOS: solo se hace backup si no hay uno, porque un segundo
    # backup sobre un AppImage ya parcheado destruiría el original.
    if [ ! -f "$orig" ]; then
        cp "$img" "$orig"
        echo "backup  → $orig"
    else
        echo "backup  → ya existía, se reutiliza"
    fi

    off="$(appimage_offset "$orig")"

    # Compresión y tamaño de bloque se leen del squashfs original en vez de
    # fijarse, para reempaquetar con los mismos parámetros si algún día la
    # build cambia (p. ej. de gzip a zstd).
    bs="$(le_int "$orig" $(( off + 12 )) 4)"
    case "$(le_int "$orig" $(( off + 20 )) 2)" in
        1) comp=gzip ;;  2) comp=lzma ;;  3) comp=lzo ;;
        4) comp=xz   ;;  5) comp=lz4  ;;  6) comp=zstd ;;
        *) die "compresión de squashfs desconocida en $orig" ;;
    esac
    echo "appimage→ offset $off, squashfs $comp, bloque $bs"

    # Se extrae el AppDir del backup, nunca del archivo en uso.
    appdir="$TMP/AppDir"
    rm -rf "$appdir"
    unsquashfs -no-progress -o "$off" -d "$appdir" "$orig" >/dev/null

    love="$(find "$appdir" -maxdepth 2 -name '*.love' -type f | head -1)"
    [ -n "$love" ] || die "no hay ningún .love dentro del AppImage"
    echo "paquete → ${love#$appdir/}"

    # El .love va suelto dentro del AppDir (no fusionado al intérprete), así
    # que la cirugía es la misma que en macOS: se parchea sobre sí mismo, que
    # aquí es seguro porque el AppDir salió del backup limpio.
    patch_love "$love" "$love"

    # Reempaquetado. Se conservan los bytes del runtime original en vez de usar
    # appimagetool: habría que descargarlo, y dentro de un contenedor necesita
    # --appimage-extract-and-run por falta de FUSE. Un AppImage type 2 es
    # runtime + squashfs contiguos, así que basta concatenarlos.
    runtime="$TMP/runtime"
    head -c "$off" "$orig" > "$runtime"

    sqflags=(-root-owned -noappend -comp "$comp" -b "$bs")
    # Sin fechas, dos instalaciones dan bytes idénticos (es lo que hace
    # comprobable la idempotencia). Son flags de squashfs-tools >= 4.4; en
    # versiones viejas se omiten y el AppImage sale igual de funcional, solo
    # que no reproducible byte a byte.
    for flag in -mkfs-time -all-time; do
        if { mksquashfs -help 2>&1 || true; } | grep -q -- "$flag"; then
            sqflags+=("$flag" 0)
        fi
    done

    mksquashfs "$appdir" "$TMP/fs.sqfs" "${sqflags[@]}" >/dev/null
    cat "$runtime" "$TMP/fs.sqfs" > "$TMP/new.AppImage"

    # Se copia al final y desde un temporal: si algo hubiera fallado arriba, el
    # AppImage del usuario sigue intacto.
    cp "$TMP/new.AppImage" "$img"
    chmod +x "$img"
    echo "empaque → $img"

    # Aquí no hay nada que firmar: Linux no valida firmas del ejecutable, así
    # que el paso equivalente al codesign de macOS simplemente no existe.

    printf '\nListo. En partida, F8 suma 5 vidas y F7 suma 5000 de oro (sin límite de usos).\n'
    printf 'Para revertir: ./uninstall.sh "%s"\n' "$img"
}

# --- Despacho -------------------------------------------------------------

case "$(uname -s)" in
    Darwin) install_macos "$@" ;;
    Linux)  install_linux  "$@" ;;
    *) die "sistema no soportado: $(uname -s) (hay macOS y Linux)" ;;
esac
