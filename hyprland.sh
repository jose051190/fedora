#!/bin/bash

# --- Variáveis de Estilo para o Terminal ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m' # Cor amarela brilhante
RED='\033[0;31m'
NC='\033[0m' # Sem Cor

# Função para confirmar ações
function confirm_action {
    read -p "$(echo -e "${YELLOW}$1 (s/n)? ${NC}")" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo -e "${RED}Operação cancelada.${NC}"
        exit 1
    fi
}

# Função para instalar pacotes com verificação de erro
function install_packages {
    local packages=("$@") # Captura todos os argumentos como um array
    echo -e "${GREEN}Instalando os seguintes pacotes: ${packages[@]}${NC}"
    sudo pacman -S --noconfirm --needed "${packages[@]}" # Adicionado --needed aqui
    if [ $? -ne 0 ]; then
        echo -e "${RED}Erro ao instalar pacotes. Verifique sua conexão com a internet ou os nomes dos pacotes.${NC}"
        exit 1
    fi
}

# Função para instalar pacotes do AUR via yay
function install_aur_packages {
    local packages=("$@")
    if command -v yay &> /dev/null; then
        echo -e "${GREEN}Instalando pacotes do AUR via yay: ${packages[@]}${NC}"
        yay -S --noconfirm "${packages[@]}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Erro ao instalar pacotes do AUR via yay. Por favor, verifique manualmente.${NC}"
        fi
    else
        echo -e "${RED}O comando 'yay' não foi encontrado. Não é possível instalar pacotes do AUR sem ele.${NC}"
        echo -e "${YELLOW}Por favor, instale 'yay' manualmente para instalar estes pacotes.${NC}"
    fi
}

# --- Início do Script de Instalação do Hyprland ---

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}  Script de Instalação do Hyprland no Arch Linux    ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo
echo -e "${YELLOW}Este script irá instalar o Hyprland e suas dependências em seu sistema Arch Linux minimalista.${NC}"
echo -e "${YELLOW}Sua placa de vídeo RX 580 será configurada com os drivers Mesa (open-source), que são os mais adequados.${NC}"
echo -e "${YELLOW}O processador Xeon X79 não requer configurações especiais para o Hyprland.${NC}"
echo
echo -e "${YELLOW}Certifique-se de ter uma conexão ativa e estável com a internet.${NC}"
echo -e "${YELLOW}Você será solicitado a confirmar as instalações em várias etapas.${NC}"
echo

confirm_action "Deseja iniciar a instalação do Hyprland e seus componentes?"

# 1. Atualizar o sistema
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 1: Atualizando o sistema base...${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
sudo pacman -Syu --noconfirm
if [ $? -ne 0 ]; then
    echo -e "${RED}Erro ao atualizar o sistema. Por favor, verifique sua conexão ou os espelhos do Pacman.${NC}"
    exit 1
fi
echo -e "${GREEN}Sistema atualizado com sucesso.${NC}"
echo

# 2. Instalar drivers gráficos (Mesa para RX 580) e dependências base do Wayland
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 2: Instalando drivers gráficos (Mesa para RX 580) e dependências base do Wayland.${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
# 'mesa' para GPUs AMD/Intel
# 'git' para clonar repositórios (se necessário, embora priorizemos pacman)
# 'libinput' para gerenciamento de entrada
# 'wayland-protocols' para definições de protocolo Wayland
install_packages mesa git libinput wayland-protocols

echo -e "${GREEN}Drivers gráficos e dependências base do Wayland instalados.${NC}"
echo

# 3. Instalar Hyprland Core e XWayland
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 3: Instalando Hyprland Core e XWayland para compatibilidade com aplicações X11.${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
# 'hyprland': O compositor Wayland
# 'hyprpaper': Utilitário de papel de parede nativo do Hyprland
# 'xdg-desktop-portal-hyprland': Essencial para compartilhamento de tela e portais XDG
# 'xdg-desktop-portal-gtk': Recomendado para diálogos de arquivos
# 'xorg-xwayland': Camada de compatibilidade para aplicações X11
install_packages hyprland hyprpaper xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xorg-xwayland

echo -e "${GREEN}Hyprland Core e XWayland instalados.${NC}"
echo

# 4. Instalar Aplicações Complementares Essenciais
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 4: Instalando aplicações complementares essenciais para um ambiente de trabalho funcional.${NC}"
echo -e "${GREEN}----------------------------------------------------------------------------------------------------${NC}"

# Gestor de Exibição (Display Manager) - SDDM
read -p "$(echo -e "${YELLOW}Deseja instalar o SDDM (Display Manager)? (Opcional, você pode iniciar o Hyprland manualmente de um TTY) (s/n)? ${NC}")" -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then # Início do bloco 'if' para SDDM
    install_packages sddm
    echo -e "${GREEN}Ativando o serviço SDDM para iniciar automaticamente...${NC}"
    sudo systemctl enable sddm.service
    if [ $? -ne 0 ]; then
        echo -e "${RED}Erro ao ativar o serviço SDDM. Você pode precisar ativá-lo manualmente mais tarde com 'sudo systemctl enable sddm.service'.${NC}"
    fi
fi # Fim do bloco 'if' para SDDM
echo

# Emuladores de Terminal (Apenas Kitty)
confirm_action "Deseja instalar o emulador de terminal Kitty? (Recomendado)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages kitty
fi
echo

# Barra de Status (Waybar)
confirm_action "Deseja instalar a barra de status Waybar? (Recomendado para Hyprland)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages waybar
    echo -e "${YELLOW}Lembre-se de configurar o Waybar copiando os arquivos de exemplo de /etc/xdg/waybar/ para ~/.config/waybar/.${NC}"
    echo -e "${YELLOW}E de ajustar as referências de 'sway/workspaces' para 'hyprland/workspaces' em sua configuração.${NC}"
fi
echo

# Lançadores de Aplicações (Apenas Fuzzel)
confirm_action "Deseja instalar o lançador de aplicações Fuzzel? (Recomendado)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages fuzzel
fi
echo

# Gerenciador de Arquivos (Thunar)
confirm_action "Deseja instalar o gerenciador de arquivos Thunar? (Leve e funcional)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages thunar
fi
echo

# Daemons de Notificação (mako)
confirm_action "Deseja instalar o daemon de notificação Mako? (Leve e projetado para Wayland)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages mako
fi
echo

# Ferramentas de Captura de Tela (grim, slurp)
confirm_action "Deseja instalar ferramentas de captura de tela nativas para Wayland (grim, slurp, grimshot)? (Recomendado)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages grim slurp
fi
echo

# Gerenciamento de Áudio (PipeWire e amigos)
confirm_action "Deseja instalar o PipeWire e componentes de áudio (wireplumber, pipewire-pulse, pipewire-alsa, pavucontrol)? (Altamente recomendado para áudio moderno)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages pipewire wireplumber pipewire-pulse pipewire-alsa pavucontrol
    echo -e "${GREEN}Ativando os serviços de usuário do PipeWire...${NC}"
    systemctl --user enable pipewire.service
    systemctl --user enable pipewire-pulse.service
    systemctl --user enable wireplumber.service
    echo -e "${YELLOW}Pode ser necessário reiniciar o sistema para que o áudio funcione corretamente após esta instalação.${NC}"
fi
echo

# Gerenciamento de Papel de Parede (hyprpaper já está instalado com hyprland)
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 4.I: Gerenciamento de Papel de Parede (hyprpaper já instalado).${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${YELLOW}O utilitário 'hyprpaper' já foi instalado com o Hyprland e é suficiente para definir papéis de parede.${NC}"
echo -e "${YELLOW}Você pode configurá-lo no seu arquivo ~/.config/hypr/hyprland.conf.${NC}"
echo

# Gerenciamento de Rede (NetworkManager)
confirm_action "Deseja instalar o NetworkManager e seu applet gráfico? (Altamente recomendado para gerenciar conexões de rede)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages networkmanager network-manager-applet
    echo -e "${GREEN}Ativando o serviço NetworkManager...${NC}"
    sudo systemctl enable --now NetworkManager.service
    if [ $? -ne 0 ]; then
        echo -e "${RED}Erro ao ativar o serviço NetworkManager. Você pode precisar ativá-lo manualmente mais tarde com 'sudo systemctl enable --now NetworkManager.service'.${NC}"
    fi
fi
echo

# Fontes
confirm_action "Deseja instalar fontes essenciais (noto-fonts, ttf-dejavu, ttf-liberation) e as fontes JetBrains Mono Nerd e Inconsolata? (Recomendado para melhor renderização de texto e experiência de codificação)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages noto-fonts ttf-dejavu ttf-liberation ttf-jetbrains-mono-nerd ttf-inconsolata
    echo -e "${YELLOW}Para uma renderização de fontes ainda melhor, considere configurar o FreeType subpixel hinting (consulte a Arch Wiki para detalhes).${NC}"
# Fim do bloco 'if' para Fontes
fi
echo

# Aplicações Adicionais
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 4.J: Instalando aplicações adicionais.${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"

# Player de Vídeo CLI (MPV)
confirm_action "Deseja instalar o MPV (player de vídeo CLI)? (Leve e poderoso)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages mpv
fi
echo

# Visualizador de Imagens CLI (IMV)
confirm_action "Deseja instalar o IMV (visualizador de imagens CLI para Wayland)? (Leve e funcional)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages imv
fi
echo

# Visualizador de PDF CLI (Zathura)
confirm_action "Deseja instalar o Zathura e seu plugin para PDF (zathura-pdf-poppler)? (Visualizador de PDF leve e focado em teclado)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages zathura zathura-pdf-poppler
fi
echo

# Navegador (Firefox PT-BR)
confirm_action "Deseja instalar o Firefox (versão em Português do Brasil)? (Navegador web essencial)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages firefox firefox-i18n-pt-br
fi
echo

# Calculadora (Qalculate! GTK)
confirm_action "Deseja instalar o Qalculate! GTK (calculadora poderosa com GUI)? (Recomendado)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages qalculate-gtk
fi
echo

# Editor de Notas (GNOME Text Editor)
confirm_action "Deseja instalar o GNOME Text Editor (editor de texto simples para notas)? (Leve e intuitivo)"
if [[ $REPLY =~ ^[Ss]$ ]]; then
    install_packages gnome-text-editor
fi
echo

# Seção para pacotes do AUR (VSCode, OnlyOffice)
read -p "$(echo -e "${YELLOW}Deseja instalar aplicativos do AUR (como Visual Studio Code e OnlyOffice)? (s/n)? ${NC}")" -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    if command -v yay &> /dev/null; then # Verifica se yay está realmente instalado
        # Visual Studio Code (versão da Microsoft)
        confirm_action "Deseja instalar o Visual Studio Code (versão oficial da Microsoft) via AUR? (Recomendado para desenvolvedores)"
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            install_aur_packages visual-studio-code-bin
        fi
        echo

        # OnlyOffice Desktop Editors
        confirm_action "Deseja instalar o OnlyOffice Desktop Editors via AUR? (Suíte de escritório compatível com MS Office)"
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            install_aur_packages onlyoffice
        fi
        echo
    else
        echo -e "${RED}O comando 'yay' não foi encontrado. Não é possível instalar pacotes do AUR sem ele.${NC}"
        echo -e "${YELLOW}Por favor, instale 'yay' manualmente para instalar estes pacotes.${NC}"
    fi
fi

echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${GREEN}Passo 4: Instalação de aplicações complementares concluída.${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
echo

# 5. Configuração Inicial e Próximos Passos
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}  Passos Pós-Instalação e Configuração Inicial      ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}A instalação dos pacotes foi concluída. Agora, você precisa configurar o Hyprland para personalizá-lo.${NC}"
echo
echo -e "${YELLOW}1. Crie ou edite o arquivo de configuração principal do Hyprland:${NC}"
echo -e "${YELLOW}   Recomendado: Copie o arquivo de exemplo para sua pasta de configuração pessoal:${NC}"
echo -e "${YELLOW}   ${NC}mkdir -p ~/.config/hypr"
echo -e "${YELLOW}   ${NC}cp /etc/xdg/hypr/hyprland.conf ~/.config/hypr/hyprland.conf"
echo -e "${YELLOW}   Ou crie-o manualmente: ${NC}mkdir -p ~/.config/hypr && touch ~/.config/hypr/hyprland.conf"
echo
echo -e "${YELLOW}2. Adicione as seguintes linhas ao seu arquivo ${NC}~/.config/hypr/hyprland.conf${YELLOW} para iniciar serviços essenciais e definir variáveis de ambiente:${NC}"
echo -e "${YELLOW}   ${NC}exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
echo -e "${YELLOW}   ${NC}exec-once=waybar" # Para iniciar a barra de status
echo -e "${YELLOW}   ${NC}exec-once=mako" # Para iniciar o daemon de notificações
echo -e "${YELLOW}   ${NC}exec-once=nm-applet --indicator" # Para o ícone do NetworkManager na barra
echo -e "${YELLOW}   ${NC}exec-once=hyprpaper" # Para definir o papel de parede
echo -e "${YELLOW}... e quaisquer outros programas que você queira iniciar automaticamente com o Hyprland.${NC}"
echo
echo -e "${YELLOW}3. Configure atalhos de teclado, regras de janela, animações e outras preferências no mesmo arquivo ${NC}~/.config/hypr/hyprland.conf${YELLOW}.${NC}"
echo
echo -e "${YELLOW}4. Para configurar o Waybar, copie os arquivos de exemplo e edite-os:${NC}"
echo -e "${YELLOW}   ${NC}mkdir -p ~/.config/waybar"
echo -e "${YELLOW}   ${NC}cp /etc/xdg/waybar/config ~/.config/waybar/config"
echo -e "${YELLOW}   ${NC}cp /etc/xdg/waybar/style.css ~/.config/waybar/style.css"
echo -e "${YELLOW}   Lembre-se de substituir as ocorrências de ${NC}'sway/workspaces'${YELLOW} por ${NC}'hyprland/workspaces'${YELLOW} na configuração do Waybar para compatibilidade total.${NC}"
echo
echo -e "${YELLOW}5. Reinicie o sistema para aplicar todas as alterações e iniciar o Hyprland:${NC}"
echo -e "${YELLOW}   ${NC}sudo reboot${NC}"
echo -e "${YELLOW}Após reiniciar, se você instalou o SDDM, selecione 'Hyprland' no seu Display Manager na tela de login. Caso contrário, inicie-o manualmente de um TTY (Ctrl+Alt+F2) digitando 'Hyprland'.${NC}"
echo
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}  Instalação do Hyprland Concluída!                ${NC}"
echo -e "${GREEN}  Aproveite seu novo ambiente altamente personalizável.${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}Para mais personalização e resolução de problemas, consulte a Wiki oficial do Hyprland e explore as coleções de 'dotfiles' da comunidade.${NC}"
echo
