#!/bin/bash
set -e # Sai imediatamente se qualquer comando falhar

# ===============================
# VARIÁVEIS GLOBAIS
# ===============================
MOUNT_DIR="/mnt"
BOOT_DIR="$MOUNT_DIR/boot/efi" # Para GRUB. systemd-boot ainda usa /boot/efi.
BTRFS_OPTS="defaults,noatime,compress=zstd"

# Variáveis que serão preenchidas interativamente
USERNAME=""
HOSTNAME=""
TIMEZONE="" # Será preenchido por dialog
LOCALE="pt_BR.UTF-8" # Default, pode ser interativo se desejar

# Armazena a escolha do bootloader para uso posterior nas fases
BOOTLOADER_CHOICE=""
# Variáveis para armazenar informações das partições, necessárias globalmente para o chroot
particao_boot=""
particao_raiz=""

# Variáveis para o dialog (ajuste conforme necessário, 0 0 0 para auto-tamanho)
DIALOG_HEIGHT=0
DIALOG_WIDTH=0
DIALOG_MENU_HEIGHT=0

# ===============================
# LISTAS DE PACOTES
# ===============================

# Pacotes base para pacstrap
PACOTES_BASE="base linux linux-firmware nano base-devel intel-ucode networkmanager network-manager-applet bash-completion linux-headers"

# Pacotes essenciais para a fase chroot (sem drivers ou bootloaders, sem zram-generator duplicado)
ESSENTIAL_PACKAGES_CHROOT=(
  bluez bluez-utils bluez-plugins
  git wget curl dialog # dialog é essencial para a UI
  xdg-utils xdg-user-dirs
  ntfs-3g mtools dosfstools
  gst-plugins-good
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  sof-firmware
  btrfs-progs # Para ferramentas BTRFS dentro do sistema instalado
)

# Pacotes de drivers AMD (xf86-video-amdgpu opcional via dialog)
AMD_DRIVER_PACKAGES=(
  mesa lib32-mesa
  vulkan-radeon lib32-vulkan-radeon
  libva-mesa-driver lib32-libva-mesa-driver
  mesa-vdpau lib32-mesa-vdpau
  vulkan-icd-loader lib32-vulkan-icd-loader
  vulkan-mesa-layers
  xf86-video-amdgpu # Opcional para Wayland (XWayland)/X11, será perguntado
)

# Pacotes adicionais (inclui zram-generator, yay dependências, etc.)
PACOTES_ADICIONAIS=(
  wl-clipboard npm fwupd fzf syncthing ttf-nerd-fonts-symbols inter-font ttf-jetbrains-mono plymouth neovim rclone fastfetch htop ncdu virt-manager qemu-full ebtables iptables-nft dnsmasq edk2-ovmf spice-vdagent firewalld chromium flatpak cryfs pacman-contrib pacutils expac less ksystemlog rsync sshfs go docker docker-compose toolbox cronie
  zram-generator # Movido para cá para evitar duplicação com ESSENTIAL_PACKAGES_CHROOT
)

# ===============================
# CONFIGURAÇÃO DE LOG E CORES
# ===============================
LOG_FILE="install.log"
# Redireciona a saída do script para o log e para o terminal.
# Para o dialog funcionar corretamente, sua saída de interface deve ir para /dev/tty.
# A linha 'exec > >(tee -ia "$LOG_FILE") 2>&1' foi removida devido a problemas de compatibilidade POSIX.
# O log agora é feito via redireção manual nos comandos ou tee.
# O cabeçalho 'exec' é mais complexo em scripts puramente POSIX-compatíveis.

# Cores para terminal
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ===============================
# FUNÇÕES DE MENSAGEM E ERRO
# ===============================

# Manda mensagem para o terminal e para o log
msg() {
    echo -e "${BLUE}==>${RESET} $1" | tee -a "$LOG_FILE" >/dev/tty
    dialog --backtitle "Instalação Arch Linux" --title "Progresso" --infobox "$1" $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty
    sleep 1 # Pequena pausa para a infobox ser visível
}
# Manda mensagem de sucesso
success() {
    echo -e "${GREEN}✓${RESET} $1" | tee -a "$LOG_FILE" >/dev/tty
    dialog --backtitle "Instalação Arch Linux" --title "Sucesso" --msgbox "$1" $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty
}
# Manda mensagem de aviso
warn() {
    echo -e "${YELLOW}!${RESET} $1" | tee -a "$LOG_FILE" >/dev/tty
    dialog --backtitle "Instalação Arch Linux" --title "Aviso" --msgbox "$1" $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty
}
# Manda mensagem de erro e aborta o script
error() {
    echo -e "${RED}✗${RESET} $1" | tee -a "$LOG_FILE" >/dev/tty
    dialog --backtitle "Instalação Arch Linux" --title "ERRO CRÍTICO" --msgbox "$1\n\nInstalação abortada." $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty
    exit 1
}

# ===============================
# FUNÇÕES DE VERIFICAÇÃO
# ===============================

# Verifica se o script está sendo executado como root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Este script deve ser executado como root."
    fi
}

# Verifica se o utilitário 'dialog' está instalado
check_dialog() {
    if ! type dialog >/dev/null 2>&1; then
        echo -e "${RED}Erro: O utilitário 'dialog' não está instalado. Por favor, instale-o com 'pacman -S dialog' antes de executar o script.${RESET}" >&2
        exit 1
    fi
}

# ===============================
# FASE 1: Configuração Pré-Chroot (Executado no ambiente Live ISO)
# ===============================
pre_chroot_setup() {
    check_root
    check_dialog

    msg "Ajustando idioma do sistema para pt_BR.UTF-8..."
    grep -q "pt_BR.UTF-8 UTF-8" /etc/locale.gen || echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen || warn "Não foi possível adicionar pt_BR.UTF-8 ao locale.gen."
    locale-gen || error "Falha ao gerar locales."
    export LANG="pt_BR.UTF-8" # Define o LANG para a sessão atual
    success "Idioma ajustado."

    msg "Ativando sincronização de tempo (NTP)..."
    timedatectl set-ntp true || error "Falha ao ativar sincronização de tempo."
    success "Sincronização de tempo ativada."

    # ===============================
    # SELEÇÃO DE DISCO (COM DIALOG --MENU)
    # ===============================
    msg "Listando discos disponíveis..."
    local DISCOS_FOUND=0
    local DISCOS_MENU_OPTIONS="" # Armazenará os pares "tag" "item" para o dialog

    # Usar um arquivo temporário para a saída do lsblk para evitar substituição de processo
    local LSBLK_TEMP_FILE=$(mktemp)
    lsblk -d -o NAME,SIZE,MODEL | grep -vE "loop|sr0|zram" | tail -n +2 > "$LSBLK_TEMP_FILE" || error "Falha ao listar discos."

    # Verificar se algum disco foi encontrado
    if [ ! -s "$LSBLK_TEMP_FILE" ]; then # -s verifica se o arquivo não está vazio
        error "Nenhum disco disponível encontrado para instalação."
    fi

    # Ler o arquivo temporário linha por linha para construir as opções do menu
    while IFS= read -r disco_line; do
        local DISCO_NAME_ONLY=$(echo "$disco_line" | awk '{print $1}')
        local DISCO_INFO=$(echo "$disco_line" | sed "s/^$DISCO_NAME_ONLY //")
        # Adicionar à string, garantindo aspas adequadas para o parsing do dialog
        DISCOS_MENU_OPTIONS="$DISCOS_MENU_OPTIONS \"$DISCO_NAME_ONLY\" \"$DISCO_INFO\""
        DISCOS_FOUND=$((DISCOS_FOUND + 1))
    done < "$LSBLK_TEMP_FILE"

    rm -f "$LSBLK_TEMP_FILE" # Limpar o arquivo temporário

    if [ "$DISCOS_FOUND" -eq 0 ]; then
        error "Nenhum disco disponível encontrado para instalação após processamento."
    fi

    # Executa o dialog e captura a escolha
    DISCO_NAME=$(dialog --backtitle "Instalação Arch Linux" \
                        --title "Seleção de Disco" \
                        --menu "Selecione o disco para instalar o sistema:" \
                        $DIALOG_HEIGHT $DIALOG_WIDTH $DIALOG_MENU_HEIGHT \
                        $DISCOS_MENU_OPTIONS 2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then # $? é o código de saída do último comando (dialog)
        error "Seleção de disco cancelada. Operação abortada."
    fi

    DISCO="/dev/$DISCO_NAME"
    success "Disco selecionado: $DISCO"

    # ===============================
    # CONFIRMAÇÃO DE FORMATAÇÃO (COM DIALOG --YESNO)
    # ===============================
    warn "Todos os dados em $DISCO serão APAGADOS! Esta ação é irreversível."
    dialog --backtitle "Instalação Arch Linux" \
           --title "Confirmação Crítica" \
           --yesno "ATENÇÃO: Todos os dados em $DISCO serão APAGADOS!\n\nDeseja continuar e formatar automaticamente?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    response=$?
    if [ "$response" -ne 0 ]; then
        error "Operação de instalação cancelada pelo usuário."
    fi
    success "Confirmação de formatação recebida."

    # ===============================
    # PARTICIONAMENTO, FORMATAÇÃO E SUBVOLUMES BTRFS
    # ===============================
    msg "Particionando disco: $DISCO..."
    parted -s "$DISCO" mklabel gpt || error "Falha ao criar label GPT em $DISCO"
    parted -s "$DISCO" mkpart ESP fat32 1MiB 1025MiB || error "Falha ao criar partição ESP."
    parted -s "$DISCO" set 1 esp on || error "Falha ao definir flag ESP."
    parted -s "$DISCO" mkpart primary btrfs 1025MiB 100% || error "Falha ao criar partição raiz Btrfs."
    success "Particionamento concluído."

    particao_boot="${DISCO}1"
    particao_raiz="${DISCO}2"

    msg "Formatando partições..."
    mkfs.fat -F32 "$particao_boot" || error "Falha ao formatar partição de boot ($particao_boot)."
    wipefs -a "$particao_raiz" || warn "Falha ao limpar assinaturas da partição raiz. Continuar..."
    mkfs.btrfs -f "$particao_raiz" || error "Falha ao formatar partição raiz como Btrfs ($particao_raiz)."
    success "Formatação concluída."

    msg "Criando subvolumes Btrfs..."
    mkdir -p "$MOUNT_DIR" || error "Falha ao criar diretório de montagem temporário."
    mount "$particao_raiz" "$MOUNT_DIR" || error "Falha ao montar partição raiz temporariamente."
    btrfs subvolume create "$MOUNT_DIR/@root" || error "Falha ao criar subvolume @root."
    btrfs subvolume create "$MOUNT_DIR/@home" || error "Falha ao criar subvolume @home."
    umount "$MOUNT_DIR" || error "Falha ao desmontar partição raiz temporariamente."
    success "Subvolumes Btrfs criados."

    msg "Montando sistema de arquivos..."
    mount -o "$BTRFS_OPTS,subvol=@root" "$particao_raiz" "$MOUNT_DIR" || error "Falha ao montar @root."
    mkdir -p "$MOUNT_DIR"/{home,boot/efi} || error "Falha ao criar diretórios home e boot/efi."
    mount -o "$BTRFS_OPTS,subvol=@home" "$particao_raiz" "$MOUNT_DIR/home" || error "Falha ao montar @home."
    mount "$particao_boot" "$BOOT_DIR" || error "Falha ao montar partição de boot."
    success "Sistema de arquivos montado."

    msg "Instalando pacotes base no novo sistema... Isso pode levar algum tempo."
    pacstrap -K "$MOUNT_DIR" $PACOTES_BASE || error "Falha no pacstrap. Verifique a conexão com a internet ou espelhamento."
    success "Pacotes base instalados."

    msg "Gerando fstab para o novo sistema..."
    genfstab -U "$MOUNT_DIR" >> "$MOUNT_DIR/etc/fstab" || error "Falha ao gerar fstab."
    success "Fstab gerado."

    success "Fase 1 (pré-chroot) concluída. Entrando no ambiente chroot para a próxima fase."

    # Chama o próprio script novamente, mas com um argumento para a fase chroot
    # O readlink -f "$0" garante o caminho absoluto do script dentro do ambiente chroot
    arch-chroot "$MOUNT_DIR" /bin/bash "$(readlink -f "$0")" --chroot-phase || error "Falha ao entrar no chroot ou executar a fase chroot."
}

# ===============================
# FASE 2: Configuração Dentro do Chroot (Conteúdo do arch_part2.sh)
# ===============================
chroot_setup() {
    msg "Iniciando a fase de configuração dentro do chroot..."

    # ===============================
    # Configurar fuso horário (Interativo)
    # ===============================
    msg "Configurando o fuso horário..."
    TIMEZONE=$(dialog --backtitle "Instalação Arch Linux" \
                      --title "Fuso Horário" \
                      --inputbox "Digite seu fuso horário (ex: America/Fortaleza):" \
                      $DIALOG_HEIGHT $DIALOG_WIDTH "America/Fortaleza" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then error "Configuração de fuso horário cancelada."; fi
    ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime || error "Falha ao configurar timezone."
    hwclock --systohc || error "Falha ao sincronizar hwclock."
    success "Fuso horário configurado."

    # ===============================
    # Configurar locale
    # ===============================
    msg "Configurando locale..."
    grep -q "$LOCALE UTF-8" /etc/locale.gen || sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen || error "Falha ao ativar locale $LOCALE."
    locale-gen || error "Falha ao gerar locale."
    echo "LANG=$LOCALE" > /etc/locale.conf || error "Falha ao definir LANG."
    success "Locale configurado."

    # ===============================
    # Configurar hostname e hosts (Interativo)
    # ===============================
    msg "Configurando hostname e hosts..."
    HOSTNAME=$(dialog --backtitle "Instalação Arch Linux" \
                      --title "Nome do Host" \
                      --inputbox "Digite o nome do host para o sistema:" \
                      $DIALOG_HEIGHT $DIALOG_WIDTH "arch" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then error "Configuração de hostname cancelada."; fi
    echo "$HOSTNAME" > /etc/hostname || warn "Falha ao definir hostname. Pode ser um problema de permissão ou arquivo existente."
    cat <<EOF > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
EOF
    success "Hostname e hosts configurados."

    # ===============================
    # Instalar pacotes essenciais (Fase 2)
    # ===============================
    msg "Instalando pacotes essenciais (Fase 2)..."
    pacman -S --needed --noconfirm "${ESSENTIAL_PACKAGES_CHROOT[@]}" || error "Falha na instalação de pacotes essenciais (chroot)."
    success "Pacotes essenciais instalados."

    # ===============================
    # Gerar initramfs
    # ===============================
    msg "Gerando initramfs..."
    mkinitcpio -P || error "Falha ao gerar initramfs."
    success "Initramfs gerado."

    # ===============================
    # Definir senha root
    # ===============================
    msg "Defina a senha do root:"
    passwd || error "Falha ao definir senha root."
    success "Senha root definida."

    # ===============================
    # Configurar pacman.conf
    # ===============================
    msg "Habilitando multilib e ajustes do pacman.conf..."
    sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf || error "Falha ao habilitar multilib."
    sed -i 's/^#Color/Color/' /etc/pacman.conf || error "Falha ao habilitar Color no pacman.conf."
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf || error "Falha ao habilitar VerbosePkgLists."
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf || error "Falha ao configurar ParallelDownloads."
    grep -q '^ParallelDownloads = 5' /etc/pacman.conf && ! grep -q 'ILoveCandy' /etc/pacman.conf && sed -i '/^ParallelDownloads = 5/a ILoveCandy' /etc/pacman.conf || warn "Falha ao adicionar ILoveCandy ou já existe."
    success "Pacman.conf configurado."

    # ===============================
    # Atualizar sistema
    # ===============================
    msg "Atualizando sistema... Isso pode levar algum tempo."
    pacman -Syu --noconfirm || error "Falha na atualização do sistema."
    success "Sistema atualizado."

    # ===============================
    # Habilitar serviços essenciais (Interativo)
    # ===============================
    msg "Habilitando serviços essenciais..."
    SERVICES_CHOICES=(
        "bluetooth.service" "Habilita suporte a Bluetooth" "ON"
        "NetworkManager" "Gerencia conexões de rede (Wi-Fi, Ethernet)" "ON"
        "libvirtd.service" "Daemon para virtualização (QEMU/KVM)" "OFF"
        "firewalld.service" "Firewall dinâmico" "ON"
        "syncthing@$USERNAME.service" "Sincronização de arquivos (por usuário)" "OFF" # Usar $USERNAME aqui
        "cronie.service" "Agendamento de tarefas (cron)" "ON"
        "docker.socket" "Socket para o daemon Docker" "OFF"
        "docker.service" "Daemon do Docker" "OFF"
        "systemd-timesyncd.service" "Sincronização de horário do sistema" "ON"
    )

    local temp_selected_services
    temp_selected_services=$(dialog --backtitle "Instalação Arch Linux" \
                               --title "Seleção de Serviços" \
                               --checklist "Selecione os serviços a serem habilitados:" \
                               $DIALOG_HEIGHT $DIALOG_WIDTH $DIALOG_MENU_HEIGHT \
                               "${SERVICES_CHOICES[@]}" 2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then warn "Seleção de serviços cancelada. Nenhum serviço habilitado agora."; fi

    for service in $temp_selected_services; do
        service=$(echo "$service" | tr -d '"') # Remove aspas do nome do serviço
        msg "Habilitando $service..."
        systemctl enable "$service" || warn "Não foi possível habilitar $service. Verifique se o pacote está instalado."
    done
    success "Serviços essenciais configurados."

    # ===============================
    # Instalar e configurar BOOTLOADER
    # ===============================
    msg "Configurando o bootloader..."
    case "$BOOTLOADER_CHOICE" in
        "grub")
            msg "Instalando e configurando GRUB..."
            pacman -S --needed --noconfirm grub os-prober efibootmgr || error "Falha ao instalar pacotes do GRUB."
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH || error "Falha em grub-install."
            sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || error "Falha ao habilitar OS Prober no GRUB."
            grub-mkconfig -o /boot/grub/grub.cfg || error "Falha ao gerar configuração do GRUB."
            success "GRUB instalado e configurado."
            ;;
        "systemd-boot")
            msg "Instalando e configurando systemd-boot..."
            # systemd-boot já vem com o pacote systemd, que é base.
            bootctl install || error "Falha ao instalar systemd-boot."

            # Criar loader.conf
            cat > /boot/efi/loader/loader.conf <<EOF
default arch.conf
timeout 5
console-mode auto
editor no
EOF
            success "loader.conf criado."

            # Copiar kernel e initramfs para a ESP (necessário para systemd-boot com Btrfs)
            mkdir -p /boot/efi/EFI/Arch || error "Falha ao criar diretório EFI/Arch na ESP."
            cp /boot/vmlinuz-linux /boot/efi/EFI/Arch/vmlinuz-linux.efi || error "Falha ao copiar vmlinuz-linux."
            cp /boot/intel-ucode.img /boot/efi/EFI/Arch/intel-ucode.img || error "Falha ao copiar intel-ucode.img."
            cp /boot/initramfs-linux.img /boot/efi/EFI/Arch/initramfs-linux.img || error "Falha ao copiar initramfs-linux.img."
            cp /boot/initramfs-linux-fallback.img /boot/efi/EFI/Arch/initramfs-linux-fallback.img || error "Falha ao copiar initramfs-linux-fallback.img."
            success "Kernels e initramfs copiados para a ESP."

            # Obter UUID da partição raiz (particao_raiz é global, definida na fase 1)
            ROOT_UUID=$(blkid -s UUID -o value "$particao_raiz")
            if [ -z "$ROOT_UUID" ]; then error "Não foi possível obter o UUID da partição raiz ($particao_raiz)."; fi

            # Parâmetros do kernel para Plymouth (será perguntado na fase final)
            PLYMOUTH_PARAMS="quiet splash rd.udev.log_priority=3 vt.global_cursor_default=0"

            # Criar boot entries
            cat > /boot/efi/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /EFI/Arch/vmlinuz-linux.efi
initrd  /EFI/Arch/intel-ucode.img
initrd  /EFI/Arch/initramfs-linux.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@root $PLYMOUTH_PARAMS
EOF
            success "/boot/efi/loader/entries/arch.conf criado."

            cat > /boot/efi/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (Fallback)
linux   /EFI/Arch/vmlinuz-linux.efi
initrd  /EFI/Arch/intel-ucode.img
initrd  /EFI/Arch/initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@root $PLYMOUTH_PARAMS
EOF
            success "/boot/efi/loader/entries/arch-fallback.conf criado."
            success "systemd-boot instalado e configurado."
            ;;
    esac

    # ===============================
    # Instalar drivers AMD (Opcional via dialog --yesno)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Drivers Gráficos" \
           --yesno "Deseja instalar os drivers gráficos AMD (incluindo xf86-video-amdgpu para compatibilidade XWayland/X11)?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Instalando drivers AMD..."
        pacman -S --needed --noconfirm "${AMD_DRIVER_PACKAGES[@]}" || error "Falha na instalação de drivers AMD."
        success "Drivers AMD instalados."
    else
        warn "Instalação de drivers AMD ignorada."
    fi

    # ===============================
    # Criar usuário e configurar sudo (Interativo)
    # ===============================
    msg "Criando usuário comum..."
    USERNAME=$(dialog --backtitle "Instalação Arch Linux" \
                      --title "Criação de Usuário" \
                      --inputbox "Digite o nome do novo usuário:" \
                      $DIALOG_HEIGHT $DIALOG_WIDTH "" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then error "Criação de usuário cancelada."; fi

    # Verificar se o usuário já existe antes de criar
    if id "$USERNAME" &>/dev/null; then
        warn "Usuário '$USERNAME' já existe. Pulando criação."
    else
        useradd -mG wheel "$USERNAME" || error "Falha ao criar usuário $USERNAME."
        msg "Defina a senha para o usuário $USERNAME:"
        passwd "$USERNAME" || error "Falha ao definir senha para $USERNAME."
    fi

    # Configurar sudo (com aviso sobre segurança)
    dialog --backtitle "Instalação Arch Linux" \
           --title "Configuração Sudo" \
           --yesno "Deseja conceder privilégios sudo completos (ALL=(ALL) ALL) ao usuário $USERNAME?\n\nAVISO: Isso pode ser um risco de segurança. Para maior segurança, configure o sudo manualmente após a instalação." \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/"$USERNAME" || error "Falha ao configurar permissões sudo para $USERNAME."
        success "Permissões sudo completas concedidas a $USERNAME."
    else
        warn "Permissões sudo completas não concedidas. Configure o sudo manualmente se necessário."
    fi

    success "Fase 2 (chroot) concluída. Prosseguindo para a fase final."
}

# ===============================
# FASE 3: Configuração Final (Conteúdo do arch_part3.sh)
# ===============================
final_setup() {
    msg "Iniciando a fase de configuração final..."

    # ===============================
    # INSTALAÇÃO DE PACOTES ADICIONAIS (Interativo via checklist)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Pacotes Adicionais" \
           --yesno "Deseja instalar o conjunto de pacotes adicionais (inclui Docker, QEMU, Neovim, etc.)?\n\nEsta é uma lista extensa e pode levar tempo." \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Instalando pacotes adicionais..."
        pacman -S --needed --noconfirm "${PACOTES_ADICIONAIS[@]}" || error "Falha na instalação dos pacotes adicionais."
        success "Pacotes adicionais instalados."
    else
        warn "Instalação de pacotes adicionais ignorada."
    fi

    # ===============================
    # CONFIGURAÇÃO DO PLYMOUTH
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Plymouth Splash Screen" \
           --yesno "Deseja configurar o Plymouth para uma tela de boot gráfica?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Configurando Plymouth..."
        # A modificação dos parâmetros do kernel para Plymouth já foi feita na fase 2,
        # dependendo da escolha do bootloader (GRUB_CMDLINE_LINUX_DEFAULT ou entries do systemd-boot).
        # Aqui apenas garantimos a adição do hook e a atualização do mkinitcpio.
        sed -i '/^HOOKS=/ s/\(base udev\)/\1 plymouth/' /etc/mkinitcpio.conf || error "Falha ao adicionar plymouth aos HOOKS."
        mkinitcpio -p linux || error "Falha ao atualizar mkinitcpio para Plymouth."
        success "Plymouth configurado com sucesso."
    else
        warn "Configuração do Plymouth ignorada."
    fi

    # ===============================
    # INSTALAÇÃO DO YAY (AUR HELPER)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "AUR Helper" \
           --yesno "Deseja instalar o Yay (AUR helper)?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Instalando Yay (AUR Helper)..."
        if ! type git &> /dev/null; then # Usando 'type' para maior compatibilidade
            warn "Git não encontrado. Instalando git para clonar Yay."
            pacman -S --noconfirm git || error "Falha ao instalar git para Yay."
        fi

        local YAY_TMP_DIR=$(mktemp -d)
        cd "$YAY_TMP_DIR" || error "Não foi possível entrar no diretório temporário para Yay."
        git clone https://aur.archlinux.org/yay.git || error "Falha ao clonar yay."
        cd yay || error "Não foi possível entrar no diretório yay."
        makepkg -si --noconfirm || error "Falha ao instalar yay."
        cd - >/dev/null # Retorna ao diretório anterior
        rm -rf "$YAY_TMP_DIR" # Limpa o diretório temporário
        success "Yay instalado com sucesso."
    else
        warn "Instalação do Yay ignorada."
    fi

    # ===============================
    # CONFIGURAÇÃO DO ZRAM E SWAPFILE
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Otimização de Memória" \
           --yesno "Deseja configurar ZRAM e um Swapfile para otimização de memória?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Configurando ZRAM..."
        # Zram-generator é um pacote opcional agora, verificar se está instalado.
        if ! pacman -Q zram-generator &>/dev/null; then
            warn "zram-generator não encontrado. Instalando..."
            pacman -S --noconfirm zram-generator || error "Falha ao instalar zram-generator."
        fi

        cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF
        success "Configuração do zram-generator criada."

        msg "Criando swapfile..."
        if [ -f /swapfile ]; then
            warn "/swapfile já existe. Pulando criação."
        else
            touch /swapfile || error "Falha ao criar /swapfile."
            chattr +C /swapfile || error "Falha ao desabilitar CoW em /swapfile."
            fallocate -l 1G /swapfile || error "Falha ao alocar 1G para /swapfile."
            chmod 600 /swapfile || error "Falha ao definir permissões para /swapfile."
            mkswap /swapfile || error "Falha ao formatar /swapfile como swap."
            swapon /swapfile || error "Falha ao ativar /swapfile."
            grep -q "/swapfile swap swap defaults 0 0" /etc/fstab || echo "/swapfile swap swap defaults 0 0" >> /etc/fstab || error "Falha ao adicionar swapfile ao fstab."
        fi
        success "Swapfile configurado."

        msg "Ajustando parâmetros sysctl para zram..."
        cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<EOF
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
        sysctl --system || error "Falha ao aplicar parâmetros sysctl."
        success "ZRAM e Swapfile configurados."
    else
        warn "Otimização de memória (ZRAM e Swapfile) ignorada."
    fi

    # ===============================
    # AJUSTES FINAIS
    # ===============================
    msg "Realizando ajustes finais..."
    # Adicionar usuário aos grupos docker e libvirt (se os serviços foram selecionados e o usuário existe)
    if id "$USERNAME" &>/dev/null; then
        # Verificar se os serviços foram habilitados antes de adicionar aos grupos
        if systemctl is-enabled -q docker.service || systemctl is-enabled -q docker.socket; then
            usermod -aG docker "$USERNAME" || warn "Falha ao adicionar $USERNAME ao grupo docker. Verifique se o serviço Docker foi habilitado e o usuário existe."
            msg "Usuário $USERNAME adicionado ao grupo docker."
        fi
        if systemctl is-enabled -q libvirtd.service; then
            usermod -aG libvirt "$USERNAME" || warn "Falha ao adicionar $USERNAME ao grupo libvirt. Verifique se o serviço libvirtd foi habilitado e o usuário existe."
            msg "Usuário $USERNAME adicionado ao grupo libvirt."
        fi
    else
        warn "Usuário '$USERNAME' não encontrado. Pulando adição a grupos docker/libvirt."
    fi

    success "Instalação do Arch Linux concluída com sucesso!"

    # ===============================
    # REINICIALIZAÇÃO DO SISTEMA
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Instalação Concluída" \
           --yesno "A instalação foi concluída com sucesso! Deseja reiniciar o sistema agora?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    response=$?
    if [ "$response" -eq 0 ]; then
        msg "Reiniciando o sistema..."
        reboot
    else
        warn "Reinicialização cancelada. Lembre-se de reiniciar manualmente para aplicar todas as alterações."
    fi
}

# ===============================
# LÓGICA PRINCIPAL DO SCRIPT
# ===============================
case "$1" in
    --chroot-phase)
        # Executado dentro do chroot
        chroot_setup
        final_setup # A fase 3 também é executada dentro do chroot
        ;;
    *)
        # Executado no ambiente Live ISO
        pre_chroot_setup
        # Após pre_chroot_setup, o script se reexecuta dentro do chroot e essa instância do script finaliza.
        ;;
esac
