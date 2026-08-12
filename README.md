# TWD Mods

Mods para **TWD — Tower Defense** (`com.tavo.twd`, LÖVE 2D 11.5), distribuidos como
un *parche* que cada usuario aplica sobre su propia copia del juego. **macOS y
Linux.**

Ahora mismo hay dos, los dos sin límite de usos: **F8 suma 5 vidas** y **F7 suma 5000
de oro** durante la partida.

> **Este repo no contiene el juego.** Se distribuye únicamente el instalador y el
> archivo del mod. Cada usuario aplica el parche sobre su copia legítima del juego
> (`TWD.app` en macOS, el AppImage en Linux). No subir aquí `twd.love`, su
> contenido extraído, el AppImage ni ningún asset del juego.

---

## 1. Instalación

**Requisitos.** En macOS, ninguno: `zip`, `unzip` y `codesign` vienen con el sistema.
En Linux hacen falta `squashfs-tools` (para abrir y cerrar el AppImage) además de
`zip`/`unzip`:

```bash
sudo apt install squashfs-tools zip unzip     # o dnf / pacman
```

**Instalar:**

```bash
git clone https://github.com/aaronUnosquare/twd-mods.git
cd twd-mods
./install.sh
```

Uso completo, igual en los dos sistemas:

```bash
./install.sh                       # busca el juego donde suele estar
./install.sh /ruta/al/juego        # TWD.app en macOS, .AppImage en Linux
./uninstall.sh                     # restaura el juego original
```

Sin argumento: en macOS `/Applications/TWD.app`; en Linux se busca
`{Chibola,TWD}*.AppImage` en `~/Applications`, `~/.local/bin`, `~/bin`,
`~/Downloads`, `~/Descargas`, `/opt` y `/usr/local/bin` (un AppImage no tiene ruta
canónica, vive donde lo dejaste).

**Reinstalar es seguro.** El instalador guarda una copia del juego original la primera
vez y construye el parche siempre a partir de ella, así que volver a pasarlo no acumula
capas: sirve para actualizar el mod. Y `./uninstall.sh` devuelve el juego byte a byte
como estaba.

**Ya en el juego:** en partida, **F8 suma 5 vidas** y **F7 suma 5000 de oro**. Ninguna
de las dos funciona en la pantalla final, con el selector de carta abierto, viendo una
repetición ni en la partida de fondo del menú.

---

## 2. Advertencias

- **Firma de código (macOS).** Modificar `Resources/` invalida `_CodeSignature` y
  macOS se niega a abrir la app. La refirma ad-hoc lo resuelve. La app ya viene sin
  notarizar (`spctl` la rechaza), así que los usuarios ya tuvieron que
  autorizarla a mano una vez. En Linux no hay equivalente: el paso simplemente no
  existe.
- **`squashfs-tools` (Linux).** Hacen falta `unsquashfs` y `mksquashfs` para abrir y
  cerrar el AppImage. El instalador lo comprueba y avisa con el nombre del paquete.
  Nota menor: si la versión es anterior a la 4.4 no existen `-mkfs-time`/`-all-time`,
  así que el instalador los omite; el AppImage sale igual de funcional, solo que no
  reproducible byte a byte.
- **Permisos.** `/Applications` puede requerir `sudo` según cómo se instaló la app.
  En Linux, igual si el AppImage está en `/opt` o `/usr/local/bin`; el instalador
  comprueba que se pueda escribir antes de tocar nada y sugiere copiarlo a `$HOME`.
- **Windows sigue sin cubrir.** La build de Windows de LÖVE normalmente va
  *fusionada* (el ZIP anexado al final del `.exe`), así que necesitaría una tercera
  rama que extraiga y re-anexe el payload. Es un problema distinto al de Linux, donde
  el `.love` va suelto dentro del AppImage y la cirugía resultó ser idéntica a la de
  macOS. Sin decidir.
- **Actualizaciones del juego.** El mod está donde el actualizador no llega
  (`conf.lua` y `mods/` del paquete instalado), así que sigue vivo tras una
  actualización. Lo que puede romperse es el *enganche*: si una versión futura renombra
  `Game:keypressed`, `self.lives` o `self.money`, el mod correspondiente deja de sumar.
  No revienta el juego — el `require` va en `pcall` y el envoltorio delega en el original.
- **El oro sí deja rastro en el perfil.** Al *retirarse* de una partida, el juego
  convierte el saldo sobrante en puntos de mejora permanentes (uno por cada 1000, con
  tope de 50). Usar F7 y retirarse infla esa conversión. Es el único efecto de los mods
  sobre el progreso persistente, y no hay forma de evitarlo sin tocar el código del
  juego (ver §6). Las vidas no bancan nada.
- **Reinstalar el juego entero** (no una actualización interna, sino sustituir
  `TWD.app` o bajar otro AppImage) sí borra el parche: hay que volver a pasar
  `install.sh`. En Linux, además, el AppImage nuevo llega sin el `.orig` al lado.
- **Leaderboard.** El mod **no** toca `src/online.lua`: los puntajes se siguen
  enviando igual que sin él (ver §6).

---

De aquí en adelante, cómo funciona y por qué. No hace falta leerlo para usar el mod.

---

## 3. Análisis del objetivo

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
| `src/game.lua` | Lógica principal. Contiene todos los puntos de enganche. En el paquete actual ya solo reenvía a `src/game/init.lua` (ver abajo) |
| `src/constants.lua` | Balance: `START_LIVES`, oro inicial por dificultad, cartas |
| `src/effects.lua` | Partículas: `implode`, `ring`, `fountain`, `coin`, `text` |
| `src/ui.lua` | HUD. `UI:punchNumber` anima los contadores; `UI.GOLD_X/Y` es el destino de las monedas |
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

Y el paquete se sigue moviendo: en el actual, **`src/game.lua` ya no es la partida**,
es un `return require("src.game.init")` de una línea. El estado vive en
`src/game/init.lua` y los ejes (`oleadas`, `construir`, `poderes`, `entrada`…) se
fusionan sobre `Game` al final. El enganche no cambia —`require("src.game")` sigue
devolviendo el `Game` ya fusionado— pero es un recordatorio de por qué los mods
comprueban lo que van a usar antes de usarlo.

Hallazgos que condicionan el diseño:

- **No existe tope de vidas.** No hay `MAX_LIVES` ni ningún `math.min` sobre
  `lives` en todo el código. Sumar vidas es seguro sin lógica de recorte.
- **Tampoco existe tope de oro.** No hay `MAX_MONEY`; el único `math.min` sobre
  `self.money` en todo el código es el robo del Saqueador. El propio juego se
  pone `demo.money = 999999` para la partida de fondo del menú.
- **Saldo y estadística son dos cosas distintas.** `self.money` es el saldo;
  `self.stats.gold` es el "oro ganado" del que viven la pantalla final, los
  logros, las misiones y la telemetría. Los seis caminos del juego que dan oro
  suman a los dos. **El mod suma solo al saldo, a propósito.**
- **El HUD y la música leen `self.lives` y `g.money` cada frame.** `UI:punchNumber`
  anima el contador solo cuando el número cambia, así que sumar basta: ningún mod
  necesita tocar UI.
- **Ya existen dos rutas que suman vidas:** `Game:takeBoon` (carta de vidas) y
  la reliquia "remache" en `Game:useRelic`, que además de sumar dispara
  `effects:implode` + `effects:ring` + `effects:text` y `Audio.play`. El mod
  copia ese gesto.
- **Y seis que suman oro**, todas con el mismo patrón: matar un enemigo, botín
  recuperado, limpiar oleada, renta de las Minas, adelantar oleada y la reliquia
  "recambio". Las dos que dan oro *de la nada* —la reliquia "botín" y el cierre de
  oleada— son las que el mod de oro copia.
- **El saldo se trunca al guardar** (`math.floor` en `src/savegame.lua`), así que
  los mods suman enteros.
- **No hay anti-trampa de ningún tipo.** Ni checksum, ni firma, ni validación
  sobre la partida guardada. Los únicos hashes del código son la verificación de
  descarga del actualizador y las semillas deterministas de música y diaria.

---

## 4. Arquitectura del mod

Regla central: **no editar el código del juego.** Los mods son *monkey-patches*
de Lua que envuelven un método en tiempo de ejecución, guardando la referencia
original y delegando en ella. Ventajas frente a editar líneas:

- Sobrevive a actualizaciones del juego.
- Es una pieza aislada; se desactiva borrando un archivo.
- El diff contra el juego original es **una sola línea**.

Dos piezas dentro del `.love` del paquete instalado:

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
desde el backup del original, nunca sobre lo ya parcheado.

---

## 5. Vidas a demanda ✅ implementado

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
`main.lua` intercepta las suyas *antes* de delegar en `scene:keypressed`, así que
cualquier F que el juego no reclame llega intacta al mod.

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

## 6. Oro a demanda ✅ implementado

`mod/gold.lua`. **F7 suma 5000 de oro, sin límite de usos.**

Es el mod de vidas con otro campo: misma estructura, mismo enganche, mismas
guardas. Lo que sigue son solo las diferencias.

**Enganche:** envolver `Game:keypressed`, igual que el de vidas. Los dos se
encadenan sin conflicto — cada uno guarda el `original` que encontró y delega en
él, así que el orden de carga (alfabético: `gold` antes que `lives`) da igual.
Cada mod lleva su propio pestillo anti-doble-carga (`Game.__modGoldOnDemand`).

**Operación:** `self.money = self.money + 5000`, y **nada más**. En particular
**no toca `self.stats.gold`**, aunque los seis caminos del juego que dan oro sí lo
hacen. Es deliberado: regalar saldo es el mod; hacer que la pantalla final, los
logros y las misiones de "gana X oro" mientan sobre lo que se ganó jugando, no.
Misma línea que el mod de vidas, que tampoco toca ninguna estadística.

**Tecla:** **F7**. Con F8 ya ocupada por el mod de vidas, las F libres son F2, F4,
F5, F6, F7, F10 y F12. Se eligió F7 por contigüidad con F8 — los dos mods quedan
juntos bajo los dedos — y descartando F10 y F12, que algunos gestores de ventanas
capturan antes de que lleguen al juego.

**Retroalimentación:** el gesto de la reliquia "botín", lo único del juego donde
aparece oro que no sale de un enemigo concreto: siete `effects:fountain` doradas
brotando del borde inferior a lo ancho del tablero (suben en vez de caer, para que
no se confundan con una entrada de enemigos), texto flotante en el centro y
`Audio.play("coin_rain")`. Más las tres monedas volando al contador del cierre de
oleada, vía `Game:rewardCoin` — se usa el ayudante y no `Effects:coin` a mano
porque el destino sale de `UI.GOLD_X/Y`: si el HUD se mueve, las monedas también.

**El texto lo compone el bioma.** No existe una clave i18n "+N ORO", y la divisa no
siempre se llama Oro: el Pantano cobra en Cacao, y `Biome:money()` pasa además por
`I18n.canon` (en inglés devuelve "Gold"). Así que el mod pregunta —
`"+5000 " .. self.biome:money():upper()`— en vez de escribir la palabra, con
`"+5000 ORO"` de reserva. Es el mismo truco que el juego usa al revés en «Sin %s»,
que llama a `:lower()`.

**Tolerancia a versiones:** lo que puede faltar se detecta antes de usarlo
(`effects:fountain`, `Game:rewardCoin`, `self.biome`, `C.color.gold`), y
`Audio.play` ya ignora en silencio los sonidos que no conoce, así que sobre un
paquete viejo el mod suma igual y solo pierde adornos.

**Sin autoguardado:** por la misma razón que el de vidas — solo es válido entre
oleadas y F7 se puede pulsar en mitad de una.

**Ajustes:** `M.KEY` y `M.GOLD`, en la cabecera de `mod/gold.lua`. `M.GOLD` debe
ser entero: el saldo se guarda con `math.floor`.

**Lo que sí se escapa al perfil.** Al *retirarse* de una partida, el juego convierte
el saldo sobrante en puntos de mejora permanentes: uno por cada 1000, con tope de
50. Regalar oro infla esa conversión, y no hay forma de evitarlo sin tocar el código
del juego — el mod no sabe, al pulsar F7, si esa partida acabará retirándose. Es la
única fuga de los dos mods hacia el progreso persistente y queda documentada, no
resuelta: coherente con la decisión de §7 sobre el leaderboard.

### Comprobado

Instalación y desinstalación sobre una **copia** de `TWD.app`: los dos mods llegan
intactos al `.love`, el cargador aparece una vez, la firma ad-hoc valida, el backup
sigue siendo el original limpio y desinstalar devuelve el `.love` byte a byte. Y la
prueba de humo de Linux en contenedor, 20/20.

La lógica del mod se ejecutó además bajo LuaJIT contra dobles de los módulos del
juego —sin OpenGL ni pantalla—: F7 suma exactamente 5000 y no toca `stats.gold`, el
texto sale del bioma ("+5000 CACAO" en el Pantano, "+5000 ORO" de reserva), las
cuatro guardas dejan caer la tecla al `keypressed` original, el resto del teclado
sigue llegando, los dos mods conviven sin pisarse y el pestillo impide envolver dos
veces.

**Lo que no está comprobado:** pulsar F7 en el juego de verdad, con ventana. Los
efectos (`fountain`, `rewardCoin`, `coin_rain`) se copiaron de rutas existentes del
juego y se llaman con las mismas firmas, pero nadie los ha visto todavía en pantalla.

---

## 7. Leaderboard — se deja como está (decidido)

El análisis original proponía neutralizar `Online.submit` (el juego publica
puntajes a un Supabase compartido) para no ensuciar la tabla de los demás.
**Descartado a propósito: el mod no toca `src/online.lua`.** Los puntajes,
récords, misiones y logros se siguen enviando y guardando exactamente igual que
sin el mod.

Consecuencia asumida: una partida con F8 o F7 puede acabar en la tabla junto a las
demás. Si algún día se quiere lo contrario, es un archivo aparte en `mods/`
(envolver `Online.submit` y salir sin enviar) — el cargador lo recogería solo,
sin tocar nada más.

Efecto de rebote que sí conviene saber: las repeticiones que graba el juego
reproducen las acciones registradas, y ni las vidas ni el oro del mod son una
acción registrada. `src/replay.lua` compara al final `wave`, `lives`, `kills`,
`leaked`, `money`, `towers` y `time`, así que una repetición de una partida con
F8 o F7 avisará de que no coincide con lo que pasó. Es cosmético.

---

## 8. Cómo está montado el instalador

```
twd-mods/
  install.sh             # aplica los mods (macOS y Linux)
  uninstall.sh           # restaura desde el backup
  mod/lives.lua          # F8: +5 vidas
  mod/gold.lua           # F7: +5000 de oro
  test/Dockerfile        # entorno Linux para probar el instalador
  test/linux-smoke.sh    # prueba de humo de la rama Linux
  README.md
  CLAUDE.md
```

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
comprueba 20 cosas: que el backup sea la descarga original byte a byte, que reinstalar
dé el mismo AppImage byte a byte, que el cargador aparezca **exactamente una vez** en
`conf.lua`, que todos los `.lua` compilen con LuaJIT, que el AppDir salga del
ida-y-vuelta por squashfs con los mismos archivos y los mismos permisos (incluido el
`+x` de `bin/love`), y que desinstalar devuelva el archivo idéntico a la descarga.
Recalcula el offset del squashfs por su cuenta, para no dar por bueno el mismo cálculo
que está verificando.

Lo que el contenedor no cubre es arrancar el juego, que necesita OpenGL y una pantalla.

---

## 9. Estado

- [x] Análisis del objetivo y puntos de enganche
- [x] Decidido: **+5 vidas por pulsación, sin límite de usos**
- [x] Decidido: **+5000 de oro por pulsación (F7), sin límite y sin tocar `stats.gold`**
- [x] Decidido: **no se toca el envío a Supabase** — se sigue enviando igual
- [x] Implementar `mod/lives.lua`
- [x] Implementar `mod/gold.lua` — el instalador no necesitó ningún cambio funcional:
      el cargador recorre `mods/` y `patch_love` copia `mod/*.lua` por glob
- [x] Implementar `install.sh` / `uninstall.sh`
- [x] Probar instalación, arranque real del juego y desinstalación limpia (macOS)
- [x] **Soporte Linux (AppImage)** — el mod no necesitó ningún cambio: solo el
      envoltorio. Instalador y prueba de humo en contenedor, 20/20
- [ ] Arrancar el juego en Linux y pulsar F8 o F7: **sin probar**. El contenedor no
      tiene OpenGL ni pantalla. El Lua que corre es el mismo `.love` ya verificado en
      macOS, así que el riesgo es bajo, pero no está comprobado
- [ ] Decidir: ¿soporte Windows? (sin hacer; requiere extraer y re-anexar el payload
      del `.exe` fusionado)
