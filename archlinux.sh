#!/bin/bash
set -e

# ===============================
# VARIÁVEIS GLOBAIS
# ===============================
MOUNT_DIR="/mnt"
BOOT_DIR="$MOUNT_DIR/boot/efi"
BTRFS_OPTS="defaults,noatime,compress=zstd"

# Pacotes base para pacstrap (sem bootloader, será condicional)
PACOTES_BASE="base linux linux-firmware nano base-devel intel-ucode networkmanager network-manager-applet bash-completion linux-headers"

# Variáveis personalizáveis (serão preenchidas interativamente)
USERNAME=""
HOSTNAME=""
TIMEZONE=""
LOCALE="pt_BR.UTF-8" # Mantido como padrão, mas pode ser interativo
BOOTLOADER_CHOICE="" # Variável para armazenar a escolha do bootloader

# Pacotes essenciais (sem drivers e bootloader, serão instalados condicionalmente)
ESSENTIAL_PACKAGES=(
  bluez bluez-utils bluez-plugins
  git wget curl dialog
  xdg-utils xdg-user-dirs
  ntfs-3g mtools dosfstools
  gst-plugins-good
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  sof-firmware
  btrfs-progs
  zram-generator # Mantido aqui, removido de PACOTES_ADICIONAIS
)

# Pacotes de drivers AMD
AMD_DRIVER_PACKAGES=(
  xf86-video-amdgpu # Driver X.org para AMDGPU (útil para XWayland)
  mesa lib32-mesa
  vulkan-radeon lib32-vulkan-radeon
  libva-mesa-driver lib32-libva-mesa-driver
  mesa-vdpau lib32-mesa-vdpau
  vulkan-icd-loader lib32-vulkan-icd-loader
  vulkan-mesa-layers
)

# Pacotes essenciais adicionais (zram-generator removido)
PACOTES_ADICIONAIS=(
  wl-clipboard npm fwupd fzf syncthing ttf-nerd-fonts-symbols inter-font ttf-jetbrains-mono plymouth neovim rclone fastfetch htop ncdu virt-manager qemu-full ebtables iptables-nft dnsmasq edk2-ovmf spice-vdagent firewalld chromium flatpak cryfs pacman-contrib pacutils expac less ksystemlog rsync sshfs go docker docker-compose toolbox cronie
)

# Variáveis para o dialog (ajuste conforme necessário, 0 0 0 para auto-tamanho)
DIALOG_HEIGHT=0
DIALOG_WIDTH=0
DIALOG_MENU_HEIGHT=0

# Log
LOG_FILE="install.log"
# Redireciona a saída para o log e para o terminal.
# Para o dialog aparecer corretamente, sua saída de interface deve ir para /dev/tty.
exec > >(tee -ia "$LOG_FILE") 2>&1

# Cores (ainda úteis para mensagens de log diretas ou fallback)
RED="\033] && error "Execute como root."
}

# ===============================
# VERIFICAR INSTALAÇÃO DO DIALOG
# ===============================
check_dialog() {
    if! command -v dialog &> /dev/null; then
        echo -e "${RED}Erro: O utilitário 'dialog' não está instalado. Por favor, instale-o com 'sudo pacman -S dialog' antes de executar o script.${RESET}" >&2
        exit 1
    fi
}

# ===============================
# FASE 1: Configuração Pré-Chroot
# ===============================
pre_chroot_setup() {
    check_root
    check_dialog

    msg "Ajustando idioma para pt_BR.UTF-8..."
    grep -q "pt_BR.UTF-8 UTF-8" /etc/locale.gen |
| echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen |
| error "Erro ao adicionar locale ao locale.gen"
    locale-gen |
| error "Erro ao gerar locale"
    export LANG=pt_BR.UTF-8

    msg "Ativando sincronização de tempo..."
    timedatectl set-ntp true |
| error "Erro ao ativar sincronização de tempo"

    # ===============================
    # SELEÇÃO DE DISCO (COM DIALOG --MENU)
    # ===============================
    msg "Listando discos disponíveis..."
    DISCOS_MENU=()
    mapfile -t discos_raw < <(lsblk -d -o NAME,SIZE,MODEL | grep -vE "loop|sr0|zram" | tail -n +2)

    if [ ${#discos_raw[@]} -eq 0 ]; then
        error "Nenhum disco disponível encontrado para instalação."
    fi

    for disco_line in "${discos_raw[@]}"; do
        DISCO_NAME_ONLY=$(echo "$disco_line" | awk '{print $1}')
        DISCO_INFO=$(echo "$disco_line" | sed "s/^$DISCO_NAME_ONLY //")
        DISCOS_MENU+=("$DISCO_NAME_ONLY" "$DISCO_INFO")
    done

    DISCO_NAME=$(dialog --backtitle "Instalação Arch Linux" \
                        --title "Seleção de Disco" \
                        --menu "Selecione o disco para instalar o sistema:" \
                        $DIALOG_HEIGHT $DIALOG_WIDTH $DIALOG_MENU_HEIGHT \
                        "${DISCOS_MENU[@]}" 2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then
        error "Seleção de disco cancelada. Operação abortada."
    fi

    DISCO="/dev/$DISCO_NAME"

    # ===============================
    # CONFIRMAÇÃO DE FORMATAÇÃO (COM DIALOG --YESNO)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Confirmação Crítica" \
           --yesno "ATENÇÃO: Todos os dados em $DISCO serão APAGADOS!\n\nDeseja continuar e formatar automaticamente?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    response=$?
    if [ "$response" -ne 0 ]; then
        error "Operação de instalação cancelada pelo usuário."
    fi

    msg "Particionando disco: $DISCO"
    parted -s "$DISCO" mklabel gpt |
| error "Erro ao criar label GPT em $DISCO"
    parted -s "$DISCO" mkpart ESP fat32 1MiB 1025MiB |
| error "Erro ao criar partição ESP"
    parted -s "$DISCO" set 1 esp on |
| error "Erro ao definir flag ESP"
    parted -s "$DISCO" mkpart primary btrfs 1025MiB 100% |
| error "Erro ao criar partição raiz Btrfs"

    particao_boot="${DISCO}1"
    particao_raiz="${DISCO}2"

    msg "Formatando partições..."
    mkfs.fat -F32 "$particao_boot" |
| error "Erro ao formatar partição de boot"
    wipefs -a "$particao_raiz" # Não é um erro se não houver assinaturas para limpar
    mkfs.btrfs -f "$particao_raiz" |
| error "Erro ao formatar partição raiz como Btrfs"

    msg "Criando subvolumes Btrfs..."
    mkdir -p "$MOUNT_DIR" |
| error "Erro ao criar diretório de montagem"
    mount "$particao_raiz" "$MOUNT_DIR" |
| error "Erro ao montar partição raiz temporariamente"
    btrfs subvolume create "$MOUNT_DIR/@root" |
| error "Erro ao criar subvolume @root"
    btrfs subvolume create "$MOUNT_DIR/@home" |
| error "Erro ao criar subvolume @home"
    umount "$MOUNT_DIR" |
| error "Erro ao desmontar partição raiz temporariamente"

    msg "Montando sistema de arquivos..."
    mount -o "$BTRFS_OPTS,subvol=@root" "$particao_raiz" "$MOUNT_DIR" |
| error "Erro ao montar @root"
    mkdir -p "$MOUNT_DIR"/{home,boot/efi} |
| error "Erro ao criar diretórios home/boot/efi"
    mount -o "$BTRFS_OPTS,subvol=@home" "$particao_raiz" "$MOUNT_DIR/home" |
| error "Erro ao montar @home"
    mount "$particao_boot" "$BOOT_DIR" |
| error "Erro ao montar partição de boot"

    msg "Instalando pacotes base... Isso pode levar algum tempo."
    pacstrap -K "$MOUNT_DIR" $PACOTES_BASE |
| error "Erro no pacstrap"

    msg "Gerando fstab..."
    genfstab -U "$MOUNT_DIR" >> "$MOUNT_DIR/etc/fstab" |
| error "Erro ao gerar fstab"

    success "Fase 1 (pré-chroot) concluída. Entrando no ambiente chroot para a próxima fase."

    # Chama o próprio script novamente, mas com um argumento para a fase chroot
    # O readlink -f "$0" garante o caminho absoluto do script
    arch-chroot "$MOUNT_DIR" /bin/bash "$(readlink -f "$0")" --chroot-phase |
| error "Erro ao entrar no chroot ou executar fase chroot"
}

# ===============================
# FASE 2: Configuração Dentro do Chroot
# ===============================
chroot_setup() {
    msg "Iniciando a fase de configuração dentro do chroot..."

    # ===============================
    # Criar usuário (Interativo, antes da seleção de serviços para syncthing@$USERNAME.service)
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
        useradd -mG wheel "$USERNAME" |
| error "Erro ao criar usuário $USERNAME"
        msg "Defina a senha para o usuário $USERNAME:"
        passwd "$USERNAME" |
| error "Erro ao definir senha para $USERNAME"
    fi

    # ===============================
    # Configurar fuso horário (Interativo)
    # ===============================
    msg "Configurando o fuso horário..."
    TIMEZONE=$(dialog --backtitle "Instalação Arch Linux" \
                      --title "Fuso Horário" \
                      --inputbox "Digite seu fuso horário (ex: America/Fortaleza):" \
                      $DIALOG_HEIGHT $DIALOG_WIDTH "America/Fortaleza" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then error "Configuração de fuso horário cancelada."; fi
    ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime |
| error "Erro ao configurar timezone"
    hwclock --systohc |
| error "Erro ao sincronizar hwclock"

    # ===============================
    # Configurar locale
    # ===============================
    msg "Configurando locale..."
    sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen |
| error "Erro ao ativar locale $LOCALE"
    locale-gen |
| error "Erro ao gerar locale"
    echo "LANG=$LOCALE" > /etc/locale.conf |
| error "Erro ao definir LANG"

    # ===============================
    # Configurar hostname e hosts (Interativo)
    # ===============================
    msg "Configurando hostname e hosts..."
    HOSTNAME=$(dialog --backtitle "Instalação Arch Linux" \
                      --title "Nome do Host" \
                      --inputbox "Digite o nome do host para o sistema:" \
                      $DIALOG_HEIGHT $DIALOG_WIDTH "arch" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then error "Configuração de hostname cancelada."; fi
    echo "$HOSTNAME" > /etc/hostname |
| error "Erro ao definir hostname"
    cat <<EOF > /etc/hosts |
| error "Erro ao criar /etc/hosts"
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
EOF

    # ===============================
    # Instalar pacotes essenciais (já definidos globalmente)
    # ===============================
    msg "Instalando pacotes essenciais (Fase 2)..."
    pacman -S --needed --noconfirm "${ESSENTIAL_PACKAGES[@]}" |
| error "Erro na instalação de pacotes essenciais"

    # ===============================
    # Gerar initramfs
    # ===============================
    msg "Gerando initramfs..."
    mkinitcpio -P |
| error "Erro ao gerar initramfs"

    # ===============================
    # Definir senha root
    # ===============================
    msg "Defina a senha do root:"
    passwd |
| error "Erro ao definir senha root"

    # ===============================
    # Configurar pacman.conf
    # ===============================
    msg "Habilitando multilib e ajustes do pacman.conf..."
    sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf |
| error "Erro ao habilitar multilib"
    sed -i 's/^#Color/Color/' /etc/pacman.conf |
| error "Erro ao habilitar Color no pacman.conf"
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf |
| error "Erro ao habilitar VerbosePkgLists"
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf |
| error "Erro ao configurar ParallelDownloads"
    grep -q '^ParallelDownloads = 5' /etc/pacman.conf &&! grep -q 'ILoveCandy' /etc/pacman.conf && sed -i '/^ParallelDownloads = 5/a ILoveCandy' /etc/pacman.conf |
| warn "Erro ao adicionar ILoveCandy (pode já existir)"

    # ===============================
    # Atualizar sistema
    # ===============================
    msg "Atualizando sistema... Isso pode levar algum tempo."
    pacman -Syu --noconfirm |
| error "Erro na atualização do sistema"

    # ===============================
    # Habilitar serviços (Interativo)
    # ===============================
    msg "Habilitando serviços essenciais..."
    SERVICES_CHOICES=(
        "bluetooth.service" "Habilita suporte a Bluetooth" "ON"
        "NetworkManager" "Gerencia conexões de rede (Wi-Fi, Ethernet)" "ON"
        "libvirtd.service" "Daemon para virtualização (QEMU/KVM)" "OFF"
        "firewalld.service" "Firewall dinâmico" "ON"
        "syncthing@$USERNAME.service" "Sincronização de arquivos (por usuário)" "OFF"
        "cronie.service" "Agendamento de tarefas (cron)" "ON"
        "docker.socket" "Socket para o daemon Docker" "OFF"
        "docker.service" "Daemon do Docker" "OFF"
        "systemd-timesyncd.service" "Sincronização de horário do sistema" "ON"
    )

    SELECTED_SERVICES=$(dialog --backtitle "Instalação Arch Linux" \
                               --title "Seleção de Serviços" \
                               --checklist "Selecione os serviços a serem habilitados:" \
                               $DIALOG_HEIGHT $DIALOG_WIDTH $DIALOG_MENU_HEIGHT \
                               "${SERVICES_CHOICES[@]}" 2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then error "Seleção de serviços cancelada."; fi

    for service in $SELECTED_SERVICES; do
        service=$(echo "$service" | tr -d '"') # Remove aspas
        msg "Habilitando $service..."
        systemctl enable "$service" |
| warn "Não foi possível habilitar $service. Verifique se o pacote está instalado."
    done

    # ===============================
    # SELEÇÃO DO BOOTLOADER (GRUB vs systemd-boot)
    # ===============================
    BOOTLOADER_CHOICE=$(dialog --backtitle "Instalação Arch Linux" \
                               --title "Seleção do Bootloader" \
                               --radiolist "Escolha o bootloader a ser instalado:" \
                               $DIALOG_HEIGHT $DIALOG_WIDTH 0 \
                               "grub" "GRUB (mais recursos, compatibilidade ampla)" "ON" \
                               "systemd-boot" "systemd-boot (mais simples, rápido, UEFI apenas)" "OFF" \
                               2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then error "Seleção do bootloader cancelada."; fi

    case "$BOOTLOADER_CHOICE" in
        "grub")
            msg "Instalando e configurando GRUB..."
            pacman -S --needed --noconfirm grub os-prober efibootmgr |
| error "Erro ao instalar pacotes do GRUB"
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH |
| error "Erro em grub-install"
            sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub |
| error "Erro ao habilitar OS Prober no GRUB"
            grub-mkconfig -o /boot/grub/grub.cfg |
| error "Erro ao gerar configuração do GRUB"
            ;;
        "systemd-boot")
            msg "Instalando e configurando systemd-boot..."
            # systemd-boot já vem com o pacote systemd, que é base.
            bootctl install |
| error "Erro ao instalar systemd-boot"

            # Criar loader.conf
            cat > /boot/efi/loader/loader.conf <<EOF |
| error "Erro ao criar /boot/efi/loader/loader.conf"
default arch.conf
timeout 5
console-mode auto
editor no
EOF

            # Copiar kernel e initramfs para a ESP (necessário para Btrfs)
            mkdir -p /boot/efi/EFI/Arch |
| error "Erro ao criar diretório EFI/Arch"
            cp /boot/vmlinuz-linux /boot/efi/EFI/Arch/vmlinuz-linux.efi |
| error "Erro ao copiar vmlinuz-linux"
            cp /boot/intel-ucode.img /boot/efi/EFI/Arch/intel-ucode.img |
| error "Erro ao copiar intel-ucode.img"
            cp /boot/initramfs-linux.img /boot/efi/EFI/Arch/initramfs-linux.img |
| error "Erro ao copiar initramfs-linux.img"
            cp /boot/initramfs-linux-fallback.img /boot/efi/EFI/Arch/initramfs-linux-fallback.img |
| error "Erro ao copiar initramfs-linux-fallback.img"

            # Obter UUID da partição raiz
            ROOT_UUID=$(blkid -s UUID -o value "$particao_raiz")

            # Criar boot entries
            cat > /boot/efi/loader/entries/arch.conf <<EOF |
| error "Erro ao criar /boot/efi/loader/entries/arch.conf"
title   Arch Linux
linux   /EFI/Arch/vmlinuz-linux.efi
initrd  /EFI/Arch/intel-ucode.img
initrd  /EFI/Arch/initramfs-linux.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@root quiet splash rd.udev.log_priority=3 vt.global_cursor_default=0
EOF

            cat > /boot/efi/loader/entries/arch-fallback.conf <<EOF |
| error "Erro ao criar /boot/efi/loader/entries/arch-fallback.conf"
title   Arch Linux (Fallback)
linux   /EFI/Arch/vmlinuz-linux.efi
initrd  /EFI/Arch/intel-ucode.img
initrd  /EFI/Arch/initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@root quiet splash rd.udev.log_priority=3 vt.global_cursor_default=0
EOF
            ;;
    esac

    # ===============================
    # Instalar drivers AMD (Opcional via dialog --yesno)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Drivers Gráficos" \
           --yesno "Deseja instalar os drivers gráficos AMD (inclui suporte X.org para XWayland)?\n\nRecomendado para a maioria dos usuários AMD." \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Instalando drivers AMD..."
        pacman -S --needed --noconfirm "${AMD_DRIVER_PACKAGES[@]}" |
| error "Erro na instalação de drivers AMD"
    else
        msg "Instalação de drivers AMD ignorada."
    fi

    # ===============================
    # Configurar sudo (com aviso sobre segurança)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Configuração Sudo" \
           --yesno "Deseja conceder privilégios sudo completos (ALL=(ALL) ALL) ao usuário $USERNAME?\n\nAVISO: Isso pode ser um risco de segurança. Para maior segurança, configure o sudo manualmente após a instalação." \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/"$USERNAME" |
| error "Erro ao configurar permissões sudo para $USERNAME"
        success "Permissões sudo completas concedidas a $USERNAME."
    else
        warn "Permissões sudo completas não concedidas. Configure o sudo manualmente se necessário."
    fi

    success "Fase 2 (chroot) concluída. Prosseguindo para a fase final."
}

# ===============================
# FASE 3: Configuração Final
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
        pacman -S --needed --noconfirm "${PACOTES_ADICIONAIS[@]}" |
| error "Erro na instalação dos pacotes adicionais"
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
        # A modificação do GRUB_CMDLINE_LINUX_DEFAULT ou dos arquivos.conf do systemd-boot
        # já foi feita na fase 2, dependendo da escolha do bootloader.
        # Aqui apenas garantimos a atualização do mkinitcpio.
        sed -i '/^HOOKS=/ s/\(base udev\)/\1 plymouth/' /etc/mkinitcpio.conf |
| error "Erro ao adicionar plymouth aos HOOKS"
        mkinitcpio -p linux |
| error "Erro ao atualizar mkinitcpio para Plymouth"
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
        if! command -v git &> /dev/null; then
            warn "Git não encontrado. Instalando git para clonar Yay."
            pacman -S --noconfirm git |
| error "Erro ao instalar git para Yay."
        fi

        YAY_TMP_DIR=$(mktemp -d)
        cd "$YAY_TMP_DIR" |
| error "Não foi possível entrar no diretório temporário para Yay."
        git clone https://aur.archlinux.org/yay.git |
| error "Erro ao clonar yay"
        cd yay |
| error "Não foi possível entrar no diretório yay"
        makepkg -si --noconfirm |
| error "Erro ao instalar yay"
        cd - >/dev/null # Retorna ao diretório anterior
        rm -rf "$YAY_TMP_DIR" # Limpa o diretório temporário
        success "Yay instalado com sucesso."
    else
        warn "Instalação do Yay ignorada."
    fi

    # ===============================
    # CONFIGURAÇÃO DO ZRAM E SWAPFILE (Interativo)
    # ===============================
    dialog --backtitle "Instalação Arch Linux" \
           --title "Otimização de Memória" \
           --yesno "Deseja configurar ZRAM e um Swapfile para otimização de memória?" \
           $DIALOG_HEIGHT $DIALOG_WIDTH 2>&1 >/dev/tty

    if [ $? -eq 0 ]; then
        msg "Configurando ZRAM..."
        if! pacman -Q zram-generator &>/dev/null; then
            warn "zram-generator não encontrado. Instalando..."
            pacman -S --noconfirm zram-generator |
| error "Erro ao instalar zram-generator."
        fi

        cat > /etc/systemd/zram-generator.conf <<EOF |
| error "Erro ao criar configuração do zram-generator"
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

        msg "Criando swapfile..."
        if [ -f /swapfile ]; then
            warn "/swapfile já existe. Pulando criação."
        else
            touch /swapfile |
| error "Erro ao criar /swapfile"
            chattr +C /swapfile |
| error "Erro ao definir chattr +C em /swapfile"
            fallocate -l 1G /swapfile |
| error "Erro ao alocar 1G para /swapfile"
            chmod 600 /swapfile |
| error "Erro ao definir permissões para /swapfile"
            mkswap /swapfile |
| error "Erro ao formatar /swapfile como swap"
            swapon /swapfile |
| error "Erro ao ativar /swapfile"
            grep -q "/swapfile swap swap defaults 0 0" /etc/fstab |
| echo "/swapfile swap swap defaults 0 0" >> /etc/fstab |
| error "Erro ao adicionar swapfile ao fstab"
        fi

        msg "Ajustando parâmetros sysctl para zram..."
        cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<EOF |
| error "Erro ao criar 99-vm-zram-parameters.conf"
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
        sysctl --system |
| error "Erro ao aplicar sysctl --system"

        success "ZRAM e Swapfile configurados com sucesso."
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
        # Nota: systemctl is-enabled -q retorna 0 se habilitado, 1 se desabilitado.
        # Usamos |
| true para evitar que set -e saia se o serviço não estiver habilitado.
        if systemctl is-enabled -q docker.service |
| systemctl is-enabled -q docker.socket |
| true; then
            usermod -aG docker "$USERNAME" |
| warn "Erro ao adicionar $USERNAME ao grupo docker. Verifique se o serviço Docker foi habilitado e o usuário existe."
            msg "Usuário $USERNAME adicionado ao grupo docker."
        fi
        if systemctl is-enabled -q libvirtd.service |
| true; then
            usermod -aG libvirt "$USERNAME" |
| warn "Erro ao adicionar $USERNAME ao grupo libvirt. Verifique se o serviço libvirtd foi habilitado e o usuário existe."
            msg "Usuário $USERNAME adicionado ao grupo libvirt."
        fi
    else
        warn "Usuário '$USERNAME' não encontrado. Pulando adição a grupos docker/libvirt."
    fi

    success "Instalação do Arch Linux concluída com sucesso!"

    # ===============================
    # Perguntar sobre reinicialização (COM DIALOG --YESNO)
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
        warn "Reinicialização cancelada. Reinicie manualmente para aplicar todas as alterações."
    fi
}

# ===============================
# LÓGICA PRINCIPAL DO SCRIPT
# ===============================
case "$1" in
    --chroot-phase)
        chroot_setup
        final_setup # A fase 3 é executada dentro do chroot
        ;;
    *)
        pre_chroot_setup
        # Após pre_chroot_setup, o script se reexecuta dentro do chroot.
        # Não há mais lógica aqui no ambiente live.
        ;;
esac
