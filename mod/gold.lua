-- Oro a demanda.
--
-- Pulsar F7 durante la partida suma oro. Sin límite de usos y sin tope: el
-- juego no tiene MAX_MONEY ni recorta `money` en ninguna parte —el único
-- `math.min` sobre el saldo es el robo del Saqueador—, así que sumar es seguro
-- sin lógica extra. El propio juego ya se pone `demo.money = 999999` para la
-- partida de fondo del menú.
--
-- Suma al SALDO (`self.money`) y a propósito NO a `self.stats.gold`, que es el
-- contador de "oro ganado" del que viven la pantalla final, los logros, las
-- misiones ("Tesorería: gana 12000") y la telemetría. Regalar saldo es el mod;
-- mentir sobre lo que se ganó jugando, no. Es la misma línea que sigue el mod
-- de vidas, que tampoco toca ninguna estadística.
--
-- Lo que sí se escapa: al RETIRARSE, `src/game/final.lua` convierte el saldo
-- sobrante en puntos de mejora permanentes (uno por cada 1000, con tope de 50).
-- Es el único efecto del mod sobre el perfil, y no hay forma de evitarlo sin
-- tocar el código del juego. Queda avisado en el README.
--
-- No edita el código del juego: envuelve `Game:keypressed` en tiempo de
-- ejecución guardando la referencia original. Como `Game.__index = Game` y las
-- partidas son `setmetatable({}, Game)`, el parche alcanza también a la que ya
-- estuviera en curso.
--
-- Se carga desde el bloque que el instalador añade a `conf.lua`, ya con
-- main.lua cargado, así que `require("src.game")` devuelve el módulo del
-- paquete que de verdad se está ejecutando (el de la actualización montada, si
-- la hay). Por eso el mod tolera versiones distintas del juego: lo que no
-- exista, se salta.

local C     = require("src.constants")
local Audio = require("src.audio")
local Game  = require("src.game")

local M = {}

M.KEY  = "f7"    -- tecla de función libre: el juego usa f1, f3, f9 y f11, y f8 es del mod de vidas
M.GOLD = 5000    -- oro por pulsación

-- Entero a propósito: `src/savegame.lua` guarda el saldo con `math.floor`, así
-- que cualquier decimal se perdería al continuar la partida.

-- Una segunda carga (dos paquetes montados con el mod, una recarga en
-- caliente) volvería a envolver el método sobre sí mismo.
if Game.__modGoldOnDemand then return M end
Game.__modGoldOnDemand = M

-- El nombre de la divisa lo pone el bioma: casi siempre "Oro", pero el Pantano
-- cobra en Cacao, y `Biome:money` pasa además por I18n.canon (en inglés
-- devuelve "Gold"). Preguntárselo al bioma en vez de escribir "ORO" aquí es lo
-- que evita que el texto flotante mienta en el mapa equivocado. El juego hace
-- lo mismo al revés en "Sin %s", que usa `:lower()`.
local function label(game, n)
    local ok, name = pcall(function() return game.biome:money() end)
    if ok and type(name) == "string" then
        return "+" .. n .. " " .. name:upper()
    end
    return "+" .. n .. " ORO"
end

local original = Game.keypressed

function Game:keypressed(key)
    if key == M.KEY
       and self.state == "playing"   -- nada de sumar en la pantalla final
       and not self.demo             -- la partida de fondo del menú no cuenta
       and not self.replaying        -- viendo una repetición el teclado es un mando
       and not self.picker           -- con el selector abierto se elige carta
    then
        self.money = self.money + M.GOLD

        local fx = self.effects
        if fx then
            local cx, cy = C.BOARD_W / 2, C.BOARD_H / 2
            local color  = (C.color and C.color.gold) or {1, 1, 1, 1}

            -- Monedas brotando del suelo a lo ancho del tablero, calcadas de la
            -- reliquia "botín" (`Game:useRelic`): es el único gesto del juego
            -- para oro que aparece de la nada y no de un enemigo concreto.
            -- Suben en vez de caer para que no se confundan con una entrada.
            if fx.fountain then
                for i = 1, 7 do
                    local mx = C.BOARD_W * (i - 0.5) / 7 + (math.random() - 0.5) * 70
                    pcall(fx.fountain, fx, mx, C.BOARD_H - 6, color, 9,
                        {speed = 470, spread = math.pi * 0.4, gravity = 620,
                         size = 4.2, life = 0.85})
                end
            end
            fx:text(cx - 52, cy - 30, label(self, M.GOLD), color)
        end

        -- Y tres monedas volando al contador, como al limpiar una oleada. Se
        -- usa el ayudante y no `Effects:coin` a mano porque el destino sale de
        -- `UI.GOLD_X/Y`: si el HUD se mueve, las monedas se mueven con él.
        if self.rewardCoin then
            for i = 1, 3 do
                pcall(self.rewardCoin, self, C.BOARD_W / 2 + (i - 2) * 30, C.BOARD_H / 2)
            end
        end

        -- El tintineo de la reliquia "botín". `Audio.play` ignora en silencio
        -- los nombres que no conoce, así que en un paquete viejo sin este
        -- sonido el mod se queda mudo en vez de romperse.
        Audio.play("coin_rain")

        -- El HUD lee `g.money` cada frame y `UI:punchNumber` anima solo cuando
        -- el número cambia: el contador dorado se ensancha solo, gratis.

        -- A propósito no se llama al autoguardado: solo es válido entre
        -- oleadas (ver la cabecera de src/savegame.lua) y aquí se puede
        -- pulsar en mitad de una. El oro extra vale para la partida en curso;
        -- continuar desde el menú restaura el saldo que hubiera guardado.
        return
    end

    return original(self, key)
end

return M
