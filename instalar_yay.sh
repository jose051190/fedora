#!/bin/bash
set -e

# Instala yay no Arch Linux (deve ser executado como usuário normal, NÃO root)
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si

echo "yay instalado com sucesso!"