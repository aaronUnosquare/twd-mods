-- Modo letal: todas las torres matan de un disparo.
--
-- F6 enciende y apaga. A diferencia de los otros dos mods, esto no es un
-- efecto puntual sino un ESTADO, así que es un interruptor y necesita verse en
-- pantalla mientras dure. Arranca apagado en cada partida.
--
-- Se engancha en `Projectile:damage_`, que es el embudo exacto de "todas las
-- torres y solo las torres": el impacto directo, el área con caída, la
-- perforación y la cadena de la Tesla desembocan ahí y en ningún otro sitio.
-- Las torres que no disparan (Faro, Mina de oro) no pasan por ahí, y las auras
-- que mojan tampoco.
--
-- NO se engancha en `Enemy:hit`, que sería lo obvio: por ahí pasan también los
-- poderes, y la Ventisca llama a `e:hit(0, slow, duration)` para congelar sin
-- dañar. Enganchar ahí convertiría "congelar" en un botón de ganar la partida.
--
-- LO IMPORTANTE, y lo que hace que este mod no sea una línea: `Enemy:hit`
-- devuelve el daño BRUTO aplicado, no la vida que quitó, y `damage_` lo suma a
-- `owner.damageTotal`. Ese número acaba en la partida guardada (`bd_dmgBy`), en
-- el PERFIL PERMANENTE (`st_dmg`, `std_<torre>`) y en el Supabase compartido
-- (`runs.dmg_by`). Un mod que disparase "daño infinito" corrompería las
-- estadísticas de daño para siempre, entre partidas. Por eso aquí se calcula el
-- daño mínimo que mata exactamente, y `damageTotal` sigue diciendo la verdad:
-- "esta torre hizo tanto daño como vida tenían los enemigos que mató". Es la
-- misma línea que sigue mod/gold.lua al no tocar `self.stats.gold`.
--
-- No edita el código del juego: envuelve cuatro métodos en tiempo de ejecución
-- guardando la referencia original y delegando en ella. Como todo lo del juego
-- va por metatablas compartidas (`Projectile.__index = Projectile`,
-- `Game.__index = Game`), los parches alcanzan también a lo que ya estuviera
-- vivo en el tablero.
--
-- Se carga desde el bloque que el instalador añade a `conf.lua`, ya con
-- main.lua cargado, así que los `require` devuelven los módulos del paquete que
-- de verdad se está ejecutando. Por eso el mod tolera versiones distintas del
-- juego: lo que no exista, se salta.

local C          = require("src.constants")
local Audio      = require("src.audio")
local Game       = require("src.game")
local Projectile = require("src.projectile")

local M = {}

M.KEY = "f6"   -- tecla de función libre: el juego usa f1, f3, f9 y f11; los mods f7 y f8

-- El interruptor vive en el MÓDULO y no en la partida porque el proyectil no
-- tiene ninguna referencia al juego: `Projectile.new` solo guarda la torre que
-- disparó. Como solo corre una partida a la vez, un booleano aquí basta; el
-- envoltorio de `Game.new` se encarga de que arranque apagado.
M.on = false

M.PILL      = "MODO LETAL"
M.LABEL_ON  = "MODO LETAL ACTIVADO"
M.LABEL_OFF = "MODO LETAL DESACTIVADO"

-- Una segunda carga (dos paquetes montados con el mod, una recarga en
-- caliente) volvería a envolver los métodos sobre sí mismos.
if Game.__modLethalMode then return M end
Game.__modLethalMode = M

-- Los textos van literales y no por `I18n.T`: no hay ninguna clave del juego
-- que sirva, y `I18n.T` de una clave inexistente IMPRIME LA CLAVE en el
-- tablero. Mejor una cadena en español que un "juego.modo_letal" en pantalla.

local okFonts, Fonts = pcall(require, "src.fonts")

-- --- El daño letal exacto --------------------------------------------------
--
-- `Enemy:hit` hace, con `d = amount * mul * (1 + crack)`:
--
--     armor = max(0, effectiveArmor() - pierce)
--     real  = max(d * 0.2, d - armor)     -- siempre pasa un mínimo del 20%
--
-- Queremos `real == hp` clavado. Despejando las dos ramas:
--
--   · si armor <= 4*hp  →  d = hp + armor   (cae en la rama `d - armor`)
--   · si armor >  4*hp  →  d = 5*hp         (cae en la rama del 20%)
--
-- Las dos dan `real == hp` exacto, y coinciden en armor == 4*hp. De ahí se
-- despeja el `amount` que hay que entregar deshaciendo el `mul` del proyectil
-- y la grieta del enemigo.
--
-- El epsilon absorbe el redondeo del ida y vuelta en coma flotante (dividir
-- por `mul` aquí y volver a multiplicar dentro de `hit`): sin él, un `real` una
-- ulp por debajo dejaría al enemigo vivo con hp = 1e-13, que es peor que
-- pasarse en una milmillonésima.
local EPSILON = 1e-9

local function lethalAmount(projectile, enemy)
    local hp = enemy.hp
    if type(hp) ~= "number" or hp <= 0 then return nil end

    -- El multiplicador del disparo contra ESTE enemigo: combo de la torre,
    -- rama Demoledor y "Verdugo de jefes". Se le pregunta al propio juego en
    -- vez de replicarlo, para que siga valiendo si cambia.
    local mul = 1
    if projectile.damageMul then
        local ok, m = pcall(projectile.damageMul, projectile, enemy)
        if ok and type(m) == "number" and m > 0 then mul = m end
    end

    -- La grieta multiplica todo el daño que entra, dentro de `hit`.
    local crack = enemy.crack
    if type(crack) ~= "number" or crack < 0 then crack = 0 end

    -- Ojo a la precedencia, que es la del juego: (flags and X) or 0.
    local pierce = (projectile.flags and projectile.flags.pierceArmor) or 0
    if type(pierce) ~= "number" then pierce = 0 end

    local armor = enemy.armor
    if enemy.effectiveArmor then
        local ok, a = pcall(enemy.effectiveArmor, enemy)
        if ok and type(a) == "number" then armor = a end
    end
    if type(armor) ~= "number" then armor = 0 end
    armor = math.max(0, armor - pierce)

    local d = (armor <= 4 * hp) and (hp + armor) or (5 * hp)
    return d * (1 + EPSILON) / (mul * (1 + crack))
end

local originalDamage = Projectile.damage_

function Projectile:damage_(enemy, amount, effects)
    -- `amount > 0` no es paranoia: convertir un golpe que no daña en uno letal
    -- sería cambiar lo que hace el juego, no potenciarlo.
    if M.on and enemy and not enemy.dead and type(amount) == "number" and amount > 0 then
        local lethal = lethalAmount(self, enemy)
        if lethal then amount = lethal end
    end

    return originalDamage(self, enemy, amount, effects)
end

-- --- El interruptor --------------------------------------------------------

local originalKeypressed = Game.keypressed

function Game:keypressed(key)
    if key == M.KEY
       and self.state == "playing"   -- nada de cambiarlo en la pantalla final
       and not self.demo             -- la partida de fondo del menú no cuenta
       and not self.replaying        -- viendo una repetición el teclado es un mando
       and not self.picker           -- con el selector abierto se elige carta
    then
        M.on = not M.on

        local color = (C.color and C.color.danger) or {1, 1, 1, 1}
        -- El banner dura 1,1 s: sirve para el FLANCO (acabas de cambiarlo).
        -- Que siga activo lo dice la píldora de abajo.
        if self.banner then
            pcall(self.banner, self, M.on and M.LABEL_ON or M.LABEL_OFF, color)
        end

        -- `overdrive` es el sonido del poder que acelera a todas las torres:
        -- el juego ya lo usa para decir "modificador global encendido".
        -- `deny` es su "no". Audio.play ignora en silencio lo que no conoce.
        Audio.play(M.on and "overdrive" or "deny")
        return
    end

    return originalKeypressed(self, key)
end

-- --- El indicador ----------------------------------------------------------
--
-- Copiado de la píldora del Botín (`GameView:drawRelics`), que es el hueco que
-- el juego reserva para "esto es lo que está pasando ahora mismo", arriba y
-- centrado sobre el tablero. `GameView` se fusiona sobre `Game`, así que
-- `Game.drawRelics` es un método normal y se envuelve como los demás.

local function drawPill(game)
    if not (okFonts and type(Fonts) == "table" and Fonts.small) then return end

    local g    = love.graphics
    local font = Fonts.small
    local w    = font:getWidth(M.PILL) + 20
    local x    = ((C.BOARD_W or 0) - w) / 2
    -- Si el Botín está activo, su píldora ocupa y=12; esta baja para no pisarla.
    local y    = ((game.bountyTimer or 0) > 0) and 40 or 12
    local col  = (C.color and C.color.danger) or {1, 1, 1}

    g.setFont(font)
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", x, y, w, 24, 6)
    g.setColor(col[1], col[2], col[3], 0.9)
    g.rectangle("line", x, y, w, 24, 6)
    g.setColor(col[1], col[2], col[3], 1)
    g.printf(M.PILL, x, y + 5, w, "center")
    -- Devolver el color a blanco: lo que dibuje después no tiene por qué
    -- heredar el rojo de esta píldora.
    g.setColor(1, 1, 1, 1)
end

local originalDrawRelics = Game.drawRelics

if originalDrawRelics then
    function Game:drawRelics(...)
        originalDrawRelics(self, ...)
        -- En pcall: un fallo dibujando no puede tumbar el frame entero.
        if M.on and not self.demo then pcall(drawPill, self) end
    end
end

-- --- Arranca apagado -------------------------------------------------------
--
-- `Game.new` es el único sitio donde nace una partida (también la demo del
-- menú y las repeticiones). Apagar aquí es lo que hace que el interruptor no se
-- quede encendido de una partida a la siguiente, y ahorra tener que guardarlo:
-- el guardado no tiene campo para esto, y apagado es el estado seguro.

local originalNew = Game.new

if originalNew then
    function Game.new(...)
        M.on = false
        return originalNew(...)
    end
end

return M
