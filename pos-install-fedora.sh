#!/bin/bash

install_flatpak() {
    package=$1
    echo "Instalando $package..."
    flatpak install -y flathub $package
}

install_flatpak_user() {
    package_url=$1
    echo "Instalando $package_url..."
    flatpak install --user $package_url
}

# Lista de pacotes para instalar
packages=(
    "com.github.neithern.g4music"
    "org.onlyoffice.desktopeditors"
    "com.visualstudio.code"
    "org.chromium.Chromium"
    "md.obsidian.Obsidian"
    "com.valvesoftware.Steam"
    "net.lutris.Lutris"
    "com.heroicgameslauncher.hgl"
    "com.jetbrains.PyCharm-Community"
    "net.agalwood.Motrix"
    "org.telegram.desktop"
    "com.mattjakeman.ExtensionManager"
    "com.vysp3r.ProtonPlus"  # Adicionando ProtonPlus à lista
)

# Instalando pacotes do flathub
for package in "${packages[@]}"; do
    install_flatpak $package
done

# Instalando pacote específico com URL
install_flatpak_user "https://sober.vinegarhq.org/sober.flatpakref"


# Caminho para o arquivo de configuração do Chromium
CONFIG_PATH="$HOME/.var/app/org.chromium.Chromium/config/chromium-flags.conf"

# Criar a pasta de configuração se não existir
mkdir -p $(dirname $CONFIG_PATH)

# Adicionar sinalizadores ao arquivo de configuração
cat <<EOL > $CONFIG_PATH
--enable-features=VaapiVideoDecoder,UseOzonePlatform
--ozone-platform=wayland
--enable-gpu-rasterization
EOL

echo "Sinalizadores configurados em $CONFIG_PATH"

flatpak override --user --env=GOOGLE_DEFAULT_CLIENT_ID=77185425430.apps.googleusercontent.com --env=GOOGLE_DEFAULT_CLIENT_SECRET=OTJgUOQcT7lO7GsGZq2G4IlT org.chromium.Chromium

# Reiniciar Chromium
flatpak run org.chromium.Chromium

