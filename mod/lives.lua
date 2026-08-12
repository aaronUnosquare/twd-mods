-- Vidas a demanda.
--
-- Pulsar F8 durante la partida suma vidas. Sin límite de usos y sin tope de
-- vidas: el juego no tiene MAX_LIVES ni recorta `lives` en ninguna parte, así
-- que sumar es seguro sin lógica extra.
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

M.KEY   = "f8"   -- tecla de función libre: el juego usa f1, f3, f9 y f11
M.LIVES = 5      -- vidas por pulsación

-- Una segunda carga (dos paquetes montados con el mod, una recarga en
-- caliente) volvería a envolver el método sobre sí mismo.
if Game.__modLivesOnDemand then return M end
Game.__modLivesOnDemand = M

-- El juego nuevo traduce los textos flotantes; el viejo no tiene i18n.
local okI18n, I18n = pcall(require, "src.i18n")

local function label(n)
    if okI18n and type(I18n) == "table" and I18n.T then
        local ok, str = pcall(I18n.T, "juego.mas_vida", n)
        if ok and type(str) == "string" then return str end
    end
    return "+" .. n .. " VIDAS"
end

local original = Game.keypressed

function Game:keypressed(key)
    if key == M.KEY
       and self.state == "playing"   -- nada de sumar en la pantalla final
       and not self.demo             -- la partida de fondo del menú no cuenta
       and not self.replaying        -- viendo una repetición el teclado es un mando
       and not self.picker           -- con el selector abierto se elige carta
    then
        self.lives = self.lives + M.LIVES

        -- Los mismos efectos que la reliquia "remache" (`Game:useRelic`), que
        -- es lo único del juego que devuelve vidas: implosión, anillo y texto
        -- flotante en el centro del tablero. El HUD y la música leen
        -- `self.lives` cada frame, así que se actualizan solos.
        local fx = self.effects
        if fx then
            local cx, cy  = C.BOARD_W / 2, C.BOARD_H / 2
            local color   = (C.color and C.color.accent) or {1, 1, 1, 1}
            if fx.implode then pcall(fx.implode, fx, cx, cy, 120, color, 30) end
            if fx.ring    then pcall(fx.ring,    fx, cx, cy, 60, color)     end
            fx:text(cx - 40, cy - 30, label(M.LIVES), color)
        end
        Audio.play("upgrade")

        -- A propósito no se llama al autoguardado: solo es válido entre
        -- oleadas (ver la cabecera de src/savegame.lua) y aquí se puede
        -- pulsar en mitad de una. Las vidas extra valen para la partida en
        -- curso; continuar desde el menú restaura las que hubiera guardadas.
        return
    end

    return original(self, key)
end

return M
