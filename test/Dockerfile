# Entorno Linux para probar la rama Linux de install.sh.
#
# Arquitectura nativa a propósito: el instalador nunca ejecuta el AppImage
# (calcula el offset del squashfs leyendo las cabeceras ELF, en vez de llamar a
# `--appimage-offset`), así que no hace falta emular x86_64 para probarlo. Solo
# se manipulan bytes.
#
# python3 está solo para el lado verificador: la prueba recalcula el offset por
# su cuenta, para no dar por bueno el mismo cálculo que está comprobando.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        zip unzip squashfs-tools file luajit python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
