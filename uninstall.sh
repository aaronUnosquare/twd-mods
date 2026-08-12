#!/usr/bin/env bash
#
# Restaura el juego al original guardado por install.sh.
#
#   ./uninstall.sh [ruta/al/juego]
#
#   macOS: la ruta es un bundle .app      (por defecto /Applications/TWD.app)
#   Linux: la ruta es un AppImage         (se busca en las rutas habituales)
#
# Como install.sh guarda el original entero, desinstalar es copiarlo de vuelta:
# no hay que deshacer el parche del cargador ni borrar mods/ a mano.

set -euo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- macOS ----------------------------------------------------------------

uninstall_macos() {
    local app="${1:-/Applications/TWD.app}"
    local res="$app/Contents/Resources"
    local love="$res/twd.love" orig="$res/twd.love.orig"

    [ -d "$app" ]  || die "no existe $app"
    [ -f "$orig" ] || die "no hay backup en $orig; nada que restaurar"

    cp "$orig" "$love"
    rm -f "$orig"
    echo "restaurado → $love"

    if command -v codesign >/dev/null; then
        codesign --force --deep --sign - "$app" >/dev/null 2>&1 \
            && echo "firma      → ad-hoc aplicada" \
            || echo "firma      → AVISO: codesign falló"
    fi

    echo "El bundle vuelve a tener el .love original."
}

# --- Linux ----------------------------------------------------------------

# Misma búsqueda que install.sh: en Linux un AppImage vive donde el usuario lo
# dejó, y el nombre depende del producto (Chibola en Linux, TWD en macOS).
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

uninstall_linux() {
    local img="${1:-}" orig

    if [ -z "$img" ]; then
        img="$(find_appimage)" \
            || die "no encuentro el AppImage; pásalo como argumento: ./uninstall.sh ruta/al/juego.AppImage"
        echo "juego      → $img"
    fi
    [ -f "$img" ] || die "no existe $img"

    orig="$img.orig"
    [ -f "$orig" ] || die "no hay backup en $orig; nada que restaurar"
    [ -w "$img" ] && [ -w "$(dirname "$img")" ] \
        || die "sin permiso de escritura en $img (prueba con sudo)"

    cp "$orig" "$img"
    rm -f "$orig"
    # El backup se copió con cp, que no arrastra el bit de ejecución si el
    # destino se recreara; se restituye explícitamente porque un AppImage sin
    # +x no arranca.
    chmod +x "$img"
    echo "restaurado → $img"

    echo "El AppImage vuelve a ser el original, byte a byte."
}

# --- Despacho -------------------------------------------------------------

case "$(uname -s)" in
    Darwin) uninstall_macos "$@" ;;
    Linux)  uninstall_linux  "$@" ;;
    *) die "sistema no soportado: $(uname -s) (hay macOS y Linux)" ;;
esac
