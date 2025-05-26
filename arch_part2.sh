#!/bin/bash

# ------------------------------
# Variáveis personalizáveis
# ------------------------------
USERNAME="jose" # Usuário que será criado
HOSTNAME="arch"
TIMEZONE="America/Fortaleza"
LOCALE="pt_BR.UTF-8"

# Pacotes essenciais (sem drivers)
ESSENTIAL_PACKAGES=(
  bluez bluez-utils bluez-plugins
  git wget curl dialog
  xdg-utils xdg-user-dirs
  ntfs-3g mtools dosfstools pavucontrol
  gst-plugins-good
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  sof-firmware
  btrfs-progs
  zram-generator
)

# Pacotes de drivers AMD
AMD_DRIVER_PACKAGES=(
  mesa lib32-mesa
  vulkan-radeon lib32-vulkan-radeon
  libva-mesa-driver lib32-libva-mesa-driver
  mesa-vdpau lib32-mesa-vdpau
  vulkan-icd-loader lib32-vulkan-icd-loader
  vulkan-mesa-layers
)

# SCRIPTS (Definidos também em arch_base.sh, usado para chamar o próximo)
SCRIPTS=("arch_part2.sh" "arch_part3.sh")

# ------------------------------
# Cores para terminal
# ------------------------------
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

# ------------------------------
# Função para verificar o status dos comandos
# ------------------------------
check_command() {
  if [ $? -ne 0 ]; then
    echo -e "${RED}Erro ao executar: $1${RESET}"
    exit 1
  else
    echo -e "${GREEN}Sucesso: $1${RESET}"
  fi
}

# ------------------------------
# Configurar fuso horário
# ------------------------------
echo -e "${YELLOW}>> Configurando o fuso horário...${RESET}"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
check_command "Configurar timezone"

hwclock --systohc
check_command "Sincronizar hwclock"

# ------------------------------
# Configurar locale
# ------------------------------
echo -e "${YELLOW}>> Configurando locale...${RESET}"
sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
check_command "Ativar locale $LOCALE"

locale-gen
check_command "Gerar locale"

echo "LANG=$LOCALE" > /etc/locale.conf
check_command "Definir LANG"

# ------------------------------
# Configurar hostname e hosts
# ------------------------------
echo -e "${YELLOW}>> Configurando hostname e hosts...${RESET}"
echo "$HOSTNAME" > /etc/hostname
check_command "Definir hostname"

cat <<EOF > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
EOF
check_command "Criar /etc/hosts"

# ------------------------------
# Instalar pacotes essenciais
# ------------------------------
echo -e "${YELLOW}>> Instalando pacotes essenciais...${RESET}"
pacman -S --needed --noconfirm "${ESSENTIAL_PACKAGES[@]}"
check_command "Instalação de pacotes essenciais"

# ------------------------------
# Gerar initramfs
# ------------------------------
echo -e "${YELLOW}>> Gerando initramfs...${RESET}"
mkinitcpio -P
check_command "Gerar initramfs"

# ------------------------------
# Definir senha root
# ------------------------------
echo -e "${YELLOW}>> Defina a senha do root:${RESET}"
passwd
check_command "Definir senha root"

# ------------------------------
# Configurar pacman.conf
# ------------------------------
echo -e "${YELLOW}>> Habilitando multilib e ajustes do pacman.conf...${RESET}"
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
grep -q '^ParallelDownloads = 5' /etc/pacman.conf && sed -i '/^ParallelDownloads = 5/a ILoveCandy' /etc/pacman.conf
check_command "Configurações do pacman.conf"

# ------------------------------
# Atualizar sistema
# ------------------------------
echo -e "${YELLOW}>> Atualizando sistema...${RESET}"
pacman -Syu --noconfirm
check_command "Atualização do sistema"

# ------------------------------
# Habilitar serviços
# ------------------------------
echo -e "${YELLOW}>> Habilitando serviços bluetooth e NetworkManager...${RESET}"
systemctl enable bluetooth.service
check_command "Habilitar bluetooth.service"

systemctl enable NetworkManager
check_command "Habilitar NetworkManager"

# ------------------------------
# Instalar e configurar systemd-boot (Substitui GRUB)
# ------------------------------
echo -e "${YELLOW}>> Instalando e configurando systemd-boot...${RESET}"

# A partição EFI já está montada em /boot (graças à alteração no arch_base.sh)
# bootctl install copiará os arquivos necessários para a partição EFI
bootctl install # O --path=/boot é o padrão quando /boot é a ESP
check_command "bootctl install"

# Criar e configurar loader.conf
echo -e "${YELLOW}>> Criando /boot/loader/loader.conf...${RESET}"
cat <<EOF > /boot/loader/loader.conf
default  arch.conf
timeout  3
console-mode auto
editor   no
EOF
check_command "Criar /boot/loader/loader.conf"

# Obter o PARTUUID da partição raiz para a entrada do boot
# Como estamos dentro do chroot, '/' é a partição raiz do sistema.
PARTUUID_RAIZ=$(findmnt -no PARTUUID /)
check_command "Obter PARTUUID da partição raiz"

# Criar a entrada de boot para o Arch Linux
echo -e "${YELLOW}>> Criando /boot/loader/entries/arch.conf...${RESET}"
cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img # Garanta que intel-ucode esteja em /boot
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID_RAIZ rw quiet splash
EOF
check_command "Criar /boot/loader/entries/arch.conf"

echo -e "${GREEN}>> systemd-boot configurado com sucesso.${RESET}"

# ------------------------------
# Instalar drivers AMD
# ------------------------------
echo -e "${YELLOW}>> Instalando drivers AMD...${RESET}"
pacman -S --needed --noconfirm "${AMD_DRIVER_PACKAGES[@]}"
check_command "Instalação de drivers AMD"

# ------------------------------
# Criar usuário e configurar sudo
# ------------------------------
echo -e "${YELLOW}>> Criando usuário $USERNAME...${RESET}"
useradd -mG wheel "$USERNAME"
check_command "Criar usuário $USERNAME"

echo -e "${YELLOW}>> Defina a senha do usuário $USERNAME:${RESET}"
passwd "$USERNAME"
check_command "Definir senha para $USERNAME"

# Configura permissões sudo para o usuário recém-criado
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
check_command "Permissões sudo para $USERNAME"

echo -e "${GREEN}>> Instalação da Parte 2 concluída com sucesso.${RESET}"

# Chama o próximo script (arch_part3.sh), passando o nome de usuário
# Removemos o 'exit' e adicionamos esta chamada para passar o controle
/bin/bash "/${SCRIPTS[1]}" "$USERNAME" || error "Erro na Parte 3"

# O script terminará aqui após a execução de arch_part3.sh
