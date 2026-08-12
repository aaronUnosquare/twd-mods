# TWD Mods

Mods para **TWD — Tower Defense** (`com.tavo.twd`, LÖVE 2D 11.5), distribuidos como
un *parche* que cada usuario aplica sobre su propia copia del juego. **macOS y
Linux.**

> **Este repo no contiene el juego.** Se distribuye únicamente el instalador y el
> archivo del mod. Cada usuario aplica el parche sobre su copia legítima del juego
> (`TWD.app` en macOS, el AppImage en Linux). No subir aquí `twd.love`, su
> contenido extraído, el AppImage ni ningún asset del juego.

---

## 1. Análisis del objetivo

TWD es un juego LÖVE 2D. El binario que lo lanza (`Contents/MacOS/love` en el
bundle, `bin/love` dentro del AppImage) es el intérprete genérico de LÖVE y **no
contiene lógica del juego**: todo vive en `twd.love`, un ZIP con 28 archivos de
código Lua en texto plano, sin ofuscación ni bytecode compilado (~453 KB de fuente,
comentarios en español). En Linux se confirma leyendo el AppDir: `bin/love` con
`lib/liblove-11.5.so` y `lib/libluajit-5.1.so.2` al lado.

Para inspeccionar la fuente, en macOS:

```bash
unzip /Applications/TWD.app/Contents/Resources/twd.love -d /tmp/twd_src
```

Y en Linux, sacando primero el AppDir del AppImage (el `--appimage-extract` no
necesita FUSE):

```bash
./Chibola-x86_64.AppImage --appimage-extract     # deja ./squashfs-root
unzip squashfs-root/twd.love -d /tmp/twd_src
```

Archivos relevantes para estos mods:

| Archivo | Qué contiene |
|---|---|
| `conf.lua` | Configuración de ventana **y arranque del autoactualizador**. Se lee antes que nada |
| `main.lua` | Punto de entrada. Despacha teclado con `scene:keypressed(key)` |
| `src/game.lua` | Lógica principal. Contiene todos los puntos de enganche |
| `src/constants.lua` | Balance: `START_LIVES`, dificultades, cartas |
| `src/online.lua` | Leaderboard vía Supabase (`Online.submit`) |

### El juego se autoactualiza (esto manda sobre todo lo demás)

`conf.lua` monta `actualizacion.love` —el paquete que el juego se descarga solo, en
el directorio de guardado— **delante** del paquete de la app:

| Sistema | Directorio de guardado |
|---|---|
| macOS | `~/Library/Application Support/twd/` |
| Linux | `~/.local/share/twd/` |

(Sin el nivel `love/` intermedio en ninguno de los dos porque el juego corre en modo
*fused*: en Linux el `AppRun` del AppImage lanza `bin/love --fused twd.love`.)

```lua
pcall(love.filesystem.mount, PACKAGE, "/")   -- sin appendToPath: va PRIMERO
```

Consecuencias:

- Con una actualización instalada, `main.lua` y todo `src/` salen de ella. El
  `twd.love` del `.app` está desactualizado y **parchearlo no hace nada**
  (comprobado: el parche en `main.lua` del bundle nunca llegó a ejecutarse).
- `conf.lua` se lee *antes* de ese montaje, así que es el único archivo del
  juego que una actualización no puede reemplazar. El propio código lo dice:
  «de todo el juego, este archivo es el ÚNICO que una actualización no puede
  cambiar». Es, por tanto, el único sitio donde un mod sobrevive a las
  actualizaciones.
- Los `mods/*.lua` sí pueden vivir en el `.love` del bundle: la actualización no
  trae esa carpeta, así que no los tapa.

Además el paquete actualizado es bastante más grande que el de fábrica (reliquias,
i18n, repeticiones, misiones…), así que los números de línea del bundle no valen:
los enganches se verificaron contra el paquete que de verdad corre.

Hallazgos que condicionan el diseño:

- **No existe tope de vidas.** No hay `MAX_LIVES` ni ningún `math.min` sobre
  `lives` en todo el código. Sumar vidas es seguro sin lógica de recorte.
- **El HUD y la música leen `self.lives` cada frame.** El número y la tensión
  musical se actualizan solos; el mod no necesita tocar UI.
- **Ya existen dos rutas que suman vidas:** `Game:takeBoon` (carta de vidas) y
  la reliquia "remache" en `Game:useRelic`, que además de sumar dispara
  `effects:implode` + `effects:ring` + `effects:text` y `Audio.play`. El mod
  copia ese gesto.

---

## 2. Arquitectura del mod

Regla central: **no editar el código del juego.** Los mods son *monkey-patches*
de Lua que envuelven un método en tiempo de ejecución, guardando la referencia
original y delegando en ella. Ventajas frente a editar líneas:

- Sobrevive a actualizaciones del juego.
- Es una pieza aislada; se desactiva borrando un archivo.
- El diff contra el juego original es **una sola línea**.

Dos piezas dentro del `.love` del bundle:

1. **`mods/<nombre>.lua`** — el mod completo, se auto-aplica al cargarse.
2. **Un cargador añadido al final de `conf.lua`** — la única modificación al
   código original.

El cargador no puede hacer el `require` ahí mismo: `conf.lua` corre *antes* de
que exista nada del juego, y cargar `src/game.lua` desde ahí lo dejaría cacheado
en `package.loaded` desde el paquete viejo (el mismo error que el propio
`conf.lua` documenta para el actualizador). Así que lo aplaza envolviendo
`love.run`:

```lua
local __twdRun = love.run          -- el boot de LÖVE ya la definió; el juego no la toca
love.run = function(...)
    -- aquí main.lua ya está cargado: require("src.game") devuelve el módulo
    -- del paquete que de verdad se está ejecutando
    ... require cada mods/*.lua en pcall ...
    return __twdRun(...)
end
```

Recorre `mods/` en vez de nombrar archivos, así que añadir un mod es soltar un
`.lua`, y cada `require` va en `pcall`: un mod roto imprime el error y el juego
arranca igual. La idempotencia sale gratis: el instalador reconstruye siempre
desde `twd.love.orig`, nunca sobre lo ya parcheado.

---

## 3. Mod A — Vidas a demanda ✅ implementado

`mod/lives.lua`. **F8 suma 5 vidas, sin límite de usos.**

**Enganche:** envolver `Game:keypressed`. Si la tecla es la del cheat, suma y
retorna; si no, delega en el original.

**Operación:** `self.lives = self.lives + N`, reutilizando lo que ya hace
`takeBoon`.

**Guardas** (copiando los idiomas que el propio juego usa):

- `self.state == "playing"` — nada de sumar en la pantalla final.
- `self.picker` cerrado: con el selector abierto el teclado está reservado para
  elegir carta.
- `not self.replaying` — viendo una repetición el teclado es un mando de vídeo.
- `not self.demo` — la partida de fondo del menú no cuenta.

**Tecla:** de las F, el juego usa `f1` (saltar tutorial), `f3` (overlay de
depuración), `f9` (playground) y `f11` (pantalla completa). **F8** está libre.

**Retroalimentación:** el gesto de la reliquia "remache", lo único del juego que
devuelve vidas: `effects:implode` + `effects:ring` + `effects:text` con el texto
traducido `juego.mas_vida` ("+5 vida") y `Audio.play("upgrade")`. Se ve como una
mecánica nativa, no como un cheat.

**Tolerancia a versiones:** el mod corre sobre el paquete que haya montado, que
no siempre será el mismo. Lo que puede faltar se detecta antes de usarlo —i18n
(`pcall(require, "src.i18n")`, con "+5 VIDAS" de reserva), `effects:implode` /
`effects:ring`, `C.color.accent`—, así que también funciona sobre el juego de
fábrica si el actualizador descarta el paquete.

**Sin autoguardado:** `takeBoon` guarda al aplicar la carta, pero el mod no.
El autoguardado solo es válido entre oleadas (ver la cabecera de
`src/savegame.lua`) y F8 se puede pulsar en mitad de una. Las vidas extra valen
para la partida en curso; continuar desde el menú restaura las guardadas.

**Ajustes:** `M.KEY` y `M.LIVES`, en la cabecera de `mod/lives.lua`. Para poner
un límite de cargas por partida bastaría un contador ahí; se descartó a
propósito: sin límite.

### Comprobado en ejecución

Con el mod instalado sobre una copia de la app y el juego arrancado de verdad
(paquete actualizado montado): el cargador entra, `3×F8` lleva 20 vidas a 35 y
deja 3 textos flotantes, y las cuatro guardas (final de partida, selector
abierto, repetición, demo) no suman nada. El resto de teclas siguen llegando al
`keypressed` original.

---

## 4. Mod B — Vida infinita (no implementado)

**Enganche:** envolver `Game:loseLives(amount, enemy)`. Es un cuello de botella
perfecto: todo el daño al jugador pasa por ahí, y su único llamador es la fuga
de enemigos. Dentro se resta la vida y se dispara `endGame("gameover")` si llega
a 0.

La versión envuelta **conserva los efectos cosméticos** (sonido, sacudida de
pantalla, el conteo de `leakedBy` que alimenta el desglose de la pantalla de
resultados) pero omite la resta y la comprobación de derrota.

**Nota:** más invasivo que el Mod A, porque intercepta la ruta de daño y puede
alterar de rebote las estadísticas de fugas. El Mod A solo suma y no toca esa
ruta.

Muy superior a poner un número gigante en `constants.lua`: eso se pierde en cada
actualización y es un diff enorme.

---

## 5. Leaderboard — se deja como está (decidido)

El análisis original proponía neutralizar `Online.submit` (el juego publica
puntajes a un Supabase compartido) para no ensuciar la tabla de los demás.
**Descartado a propósito: el mod no toca `src/online.lua`.** Los puntajes,
récords, misiones y logros se siguen enviando y guardando exactamente igual que
sin el mod.

Consecuencia asumida: una partida con F8 puede acabar en la tabla junto a las
demás. Si algún día se quiere lo contrario, es un archivo aparte en `mods/`
(envolver `Online.submit` y salir sin enviar) — el cargador lo recogería solo,
sin tocar nada más.

Efecto de rebote que sí conviene saber: las repeticiones que graba el juego
reproducen las acciones registradas, y las vidas del mod no son una acción
registrada, así que una repetición de una partida con F8 no coincidirá con lo
que pasó.

---

## 6. Instalador

```
twd-mods/
  install.sh             # aplica el mod (macOS y Linux)
  uninstall.sh           # restaura desde el backup
  mod/lives.lua          # Mod A
  test/Dockerfile        # entorno Linux para probar el instalador
  test/linux-smoke.sh    # prueba de humo de la rama Linux
  README.md
```

Uso, igual en los dos sistemas:

```bash
./install.sh                       # busca el juego donde suele estar
./install.sh /ruta/al/juego        # TWD.app en macOS, .AppImage en Linux
./uninstall.sh
```

Sin argumento: en macOS `/Applications/TWD.app`; en Linux se busca
`{Chibola,TWD}*.AppImage` en `~/Applications`, `~/.local/bin`, `~/bin`,
`~/Downloads`, `~/Descargas`, `/opt` y `/usr/local/bin` (un AppImage no tiene ruta
canónica, vive donde lo dejaste).

### Cómo está montado

El mod es el mismo en los dos sistemas, y el `.love` también: **lo único que cambia
es el envoltorio.** De ahí la forma del script — localizar y desenvolver por sistema,
parchear en común, reenvolver por sistema:

| | macOS | Linux |
|---|---|---|
| Envoltorio | bundle `TWD.app` | AppImage type 2 (ELF + squashfs) |
| Dónde está el `.love` | `Contents/Resources/twd.love` | `twd.love`, suelto en el AppDir |
| Desenvolver | — (está suelto) | `unsquashfs -o <offset>` |
| Reenvolver | — | `mksquashfs` + concatenar tras el runtime |
| Firma | `codesign --force --deep --sign -` | no aplica |

El paso del medio —backup si no lo hay, descomprimir **el backup**, copiar
`mod/*.lua` a `mods/`, añadir el cargador al final de `conf.lua`, re-empaquetar— es
literalmente el mismo código para los dos. Partir siempre del backup y no de lo ya
instalado es lo que hace que reinstalar sea idempotente y que actualizar el mod no
acumule capas de cargador.

El cargador vive en **una sola función** y no duplicado en cada rama a propósito: es
la única modificación al código del juego, y tenerlo en dos sitios sería tenerlo en
dos versiones en cuanto se toque una.

**Sobre el AppImage.** Un type 2 es un ELF con un squashfs pegado detrás; el squashfs
empieza justo tras la tabla de secciones del ELF, así que el instalador **calcula** ese
offset leyendo las cabeceras en vez de llamar a `--appimage-offset`. Eso evita tener
que ejecutar el AppImage para parchearlo (y permite inspeccionarlo desde otro sistema).
Al reempaquetar se conservan los bytes del runtime original y se reutilizan la
compresión y el tamaño de bloque que traía el squashfs: no hace falta `appimagetool`,
que habría que descargar y que dentro de un contenedor necesita
`--appimage-extract-and-run` por falta de FUSE. Se pierde la info de actualización
zsync si la hubiera, lo cual es irrelevante aquí: el juego se actualiza bajando un
`.love`, no reemplazando el AppImage.

**`uninstall.sh`:** copia el backup de vuelta, lo borra y deja el juego como estaba
(en macOS refirma; en Linux restituye el bit `+x`). Como el backup es el original
entero, no hay que deshacer el parche a mano.

### Probar la rama Linux

No hace falta una VM. El instalador solo manipula bytes —nunca ejecuta el AppImage—,
así que un contenedor de la arquitectura nativa basta y no hay que emular x86_64:

```bash
docker build -t twd-mods-test test/
docker run --rm -v "$PWD:/work:ro" -v "$PWD/downloads:/dl:ro" \
    twd-mods-test bash /work/test/linux-smoke.sh
```

Deja el AppImage en `downloads/` (ignorado por git). La prueba trabaja sobre copias y
comprueba 19 cosas: que el backup sea la descarga original byte a byte, que reinstalar
dé el mismo AppImage byte a byte, que el cargador aparezca **exactamente una vez** en
`conf.lua`, que todos los `.lua` compilen con LuaJIT, que el AppDir salga del
ida-y-vuelta por squashfs con los mismos archivos y los mismos permisos (incluido el
`+x` de `bin/love`), y que desinstalar devuelva el archivo idéntico a la descarga.
Recalcula el offset del squashfs por su cuenta, para no dar por bueno el mismo cálculo
que está verificando.

Lo que el contenedor no cubre es arrancar el juego, que necesita OpenGL y una pantalla.

---

## 7. Advertencias

- **Firma de código (macOS).** Modificar `Resources/` invalida `_CodeSignature` y
  macOS se niega a abrir la app. La refirma ad-hoc lo resuelve. La app ya viene sin
  notarizar (`spctl` la rechaza), así que los usuarios ya tuvieron que
  autorizarla a mano una vez. En Linux no hay equivalente: el paso simplemente no
  existe.
- **`squashfs-tools` (Linux).** Hacen falta `unsquashfs` y `mksquashfs` para abrir y
  cerrar el AppImage (`apt install squashfs-tools`, o `dnf`/`pacman`). El instalador
  lo comprueba y avisa con el nombre del paquete. Nota menor: si la versión es
  anterior a la 4.4 no existen `-mkfs-time`/`-all-time`, así que el instalador los
  omite; el AppImage sale igual de funcional, solo que no reproducible byte a byte.
- **Permisos.** `/Applications` puede requerir `sudo` según cómo se instaló la app.
  En Linux, igual si el AppImage está en `/opt` o `/usr/local/bin`; el instalador
  comprueba que se pueda escribir antes de tocar nada y sugiere copiarlo a `$HOME`.
- **Windows sigue sin cubrir.** La build de Windows de LÖVE normalmente va
  *fusionada* (el ZIP anexado al final del `.exe`), así que necesitaría una tercera
  rama que extraiga y re-anexe el payload. Es un problema distinto al de Linux, donde
  el `.love` va suelto dentro del AppImage y la cirugía resultó ser idéntica a la de
  macOS. Sin decidir.
- **Actualizaciones del juego.** El mod está donde el actualizador no llega
  (`conf.lua` y `mods/` del bundle), así que sigue vivo tras una actualización.
  Lo que puede romperse es el *enganche*: si una versión futura renombra
  `Game:keypressed` o `self.lives`, el mod deja de sumar. No revienta el juego —
  el `require` va en `pcall` y el envoltorio delega en el original.
- **Reinstalar el juego entero** (no una actualización interna, sino sustituir
  `TWD.app` o bajar otro AppImage) sí borra el parche: hay que volver a pasar
  `install.sh`. En Linux, además, el AppImage nuevo llega sin el `.orig` al lado.

---

## 8. Estado

- [x] Análisis del objetivo y puntos de enganche
- [x] Diseño de ambos mods
- [x] Decidido: **Mod A** (Mod B queda documentado, sin implementar)
- [x] Decidido: **+5 vidas por pulsación, sin límite de usos**
- [x] Decidido: **no se toca el envío a Supabase** — se sigue enviando igual
- [x] Implementar `mod/lives.lua`
- [x] Implementar `install.sh` / `uninstall.sh`
- [x] Probar instalación, arranque real del juego y desinstalación limpia (macOS)
- [x] **Soporte Linux (AppImage)** — el mod no necesitó ningún cambio: solo el
      envoltorio. Instalador y prueba de humo en contenedor, 19/19
- [ ] Arrancar el juego en Linux y pulsar F8: **sin probar**. El contenedor no tiene
      OpenGL ni pantalla. El Lua que corre es el mismo `.love` ya verificado en
      macOS, así que el riesgo es bajo, pero no está comprobado
- [ ] Decidir: ¿soporte Windows? (sin hacer; requiere extraer y re-anexar el payload
      del `.exe` fusionado)
