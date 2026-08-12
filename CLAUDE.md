# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

Mods para **TWD — Tower Defense** (`com.tavo.twd`, LÖVE 2D 11.5), un juego indie
distribuido como `TWD.app` en macOS y como `Chibola-x86_64.AppImage` en Linux. El repo
distribuye **solo el parche**: un mod en Lua y un instalador que cada usuario aplica
sobre su propia copia del juego.

**El repo no contiene el juego y no debe contenerlo.** `.gitignore` cubre `*.love`,
`twd_src/`, `TWD.app/`, `downloads/` y `*.AppImage`. El AppImage de `downloads/` es el
juego entero; está ahí para desarrollar y probar el instalador.

No hay build, ni lint, ni framework de tests: son tres scripts de bash y un archivo Lua.

## Comandos

```bash
./install.sh                    # busca el juego donde suele estar
./install.sh /ruta/al/juego     # TWD.app en macOS, .AppImage en Linux
./uninstall.sh

bash -n install.sh              # lo único parecido a un lint

# Prueba de humo de la rama Linux — 19 asertos, no necesita VM ni emular x86_64
docker build -t twd-mods-test test/
docker run --rm -v "$PWD:/work:ro" -v "$PWD/downloads:/dl:ro" \
    twd-mods-test bash /work/test/linux-smoke.sh
```

La prueba de humo es un solo script con secciones `=== N. ... ===`; no hay forma de
seleccionar un aserto suelto. Requiere un `.AppImage` en `downloads/`.

## La restricción que manda sobre todo: el juego se autoactualiza

Esto es lo que hay que entender antes de tocar cualquier cosa, y no se deduce leyendo un
solo archivo.

`conf.lua` del juego monta `actualizacion.love` —un paquete que el juego se descarga
solo— **delante** del paquete instalado (`love.filesystem.mount(PACKAGE, "/")`, sin
`appendToPath`). Consecuencias:

- Con una actualización instalada, `main.lua` y todo `src/` salen de **ella**, no del
  juego instalado. **Parchear el `.love` del paquete instalado no hace nada** para esos
  archivos, y los números de línea del paquete de fábrica no valen (`src/game.lua` son
  69 KB ahí y 258 KB en el paquete actualizado).
- `conf.lua` se lee *antes* de ese montaje, así que es el **único archivo que una
  actualización no puede reemplazar**: el único sitio donde un mod sobrevive.
- `mods/*.lua` sí viven en el paquete instalado, porque la actualización no trae esa
  carpeta y no los tapa.

**Verifica siempre los enganches contra el paquete que de verdad corre**, no contra el
instalado:

```bash
# macOS
unzip -l ~/Library/Application\ Support/twd/actualizacion.love
# Linux: ~/.local/share/twd/actualizacion.love
```

(Sin nivel `love/` intermedio en ninguno de los dos: el juego corre en modo *fused* — en
Linux el `AppRun` lanza `bin/love --fused twd.love`.)

El actualizador descarga un `.love` de Lua en texto plano, **el mismo para todas las
plataformas**. Por eso el código del mod es idéntico en macOS y Linux, y por eso portar
a otro sistema es siempre un problema de *envoltorio*, nunca del mod.

## Arquitectura del mod

**Regla central: no editar el código del juego.** Los mods son *monkey-patches* que
envuelven un método en tiempo de ejecución, guardando la referencia original y delegando
en ella. El diff contra el juego original es una sola línea.

Dos piezas dentro del `.love`:

1. **`mods/<nombre>.lua`** — el mod, se auto-aplica al cargarse.
2. **Un cargador al final de `conf.lua`** — la única modificación al código original.

El cargador **no puede hacer `require` ahí mismo**: `conf.lua` corre antes de que exista
nada del juego, y cargar `src/game.lua` desde ahí lo cachearía en `package.loaded` desde
el paquete viejo. Así que lo aplaza envolviendo `love.run` (que el boot de LÖVE ya
definió y el juego no redefine), momento en el que `main.lua` ya está cargado y
`require("src.game")` devuelve el módulo del paquete en uso. Recorre `mods/` en vez de
nombrar archivos —añadir un mod es soltar un `.lua`— y cada `require` va en `pcall`: un
mod roto imprime el error y el juego arranca igual.

**Tolerancia a versiones**: el mod corre sobre el paquete que haya montado, que no
siempre es el mismo. Todo lo que pueda faltar se detecta antes de usarlo (`pcall(require,
"src.i18n")`, `if fx.implode then`, `C.color and C.color.accent`). Mantén ese estilo al
añadir enganches.

## Arquitectura del instalador

`install.sh` tiene tres fases; solo la primera y la tercera dependen del sistema:

1. **Localizar y desenvolver** (por OS) → deja un `.love`.
2. **Cirugía** (`patch_love`, común) → `mods/*.lua` + cargador al final de `conf.lua`.
3. **Reenvolver** (por OS).

| | macOS | Linux |
|---|---|---|
| Envoltorio | bundle `TWD.app` | AppImage type 2 (ELF + squashfs) |
| Dónde está el `.love` | `Contents/Resources/twd.love` | `twd.love`, suelto en el AppDir |
| Desenvolver / reenvolver | — (está suelto) | `unsquashfs -o <offset>` / `mksquashfs` + concatenar tras el runtime |
| Firma | `codesign --force --deep --sign -` | no aplica |

Invariantes que hay que preservar al tocar el instalador:

- **El bloque cargador vive en una sola función (`append_loader`).** Es la única
  modificación al código del juego; duplicarlo por rama sería tenerlo en dos versiones en
  cuanto se toque una. Por eso hay un `install.sh` con `case "$(uname -s)"` y no un
  `install-linux.sh` aparte.
- **Se parte SIEMPRE del backup `.orig`, nunca de lo ya instalado.** De ahí sale la
  idempotencia: reinstalar no acumula capas de cargador. El backup se crea **solo si no
  existe**, porque sobrescribirlo con una versión ya parcheada destruiría el original para
  siempre.
- **El AppImage no se ejecuta nunca.** El offset del squashfs se calcula leyendo las
  cabeceras ELF (`e_shoff + e_shentsize·e_shnum`), no con `--appimage-offset`. Eso permite
  parchearlo e inspeccionarlo desde otro sistema, y es lo que hace que el contenedor de
  pruebas pueda ser de la arquitectura nativa sin emular x86_64.
- Al reempaquetar se conservan los bytes del runtime original y se reutilizan la
  compresión y el tamaño de bloque leídos del squashfs; nada de `appimagetool`.

## Trampas que ya costaron tiempo

- **`od -td8` no es portable.** El `od` de macOS devuelve `-64` donde el valor real es
  `191680`. `le_int()` compone los enteros byte a byte con `-tu1` a propósito; no lo
  "simplifiques" a `-tu8`/`-td8`.
- **En `test/linux-smoke.sh`, `check "desc" ! cmd` no niega nada**: `!` se pasa como
  nombre de comando. Para eso está `check_not`.
- **`mod/*.lua` se copia entero a `mods/`**, así que cualquier `.lua` que se deje en
  `mod/` se cargará como mod. No pongas ahí helpers.
- Al cambiar la rama de macOS, verifícala sobre una **copia** de `TWD.app`, no sobre la
  app real del usuario.

## Estado

`mod/lives.lua` (F8 suma 5 vidas, sin límite) es el único mod implementado; funciona en
macOS y Linux. El README documenta la decisión deliberada de **no** tocar
`src/online.lua`: los puntajes se siguen enviando al Supabase compartido.

Sin probar: arrancar el juego en Linux y pulsar F8 (el contenedor no tiene OpenGL ni
pantalla). Sin cubrir: Windows, donde la build de LÖVE va *fusionada* (el ZIP anexado al
`.exe`) y haría falta una tercera rama que extraiga y re-anexe el payload.

El README.md es el documento de diseño: explica el *por qué* de cada decisión con más
detalle que este archivo.
