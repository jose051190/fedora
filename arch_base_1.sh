#!/bin/bash
set -e

# ===============================
# VARIÁVEIS
# ===============================
MOUNT_DIR="/mnt"
BOOT_DIR="$MOUNT_DIR/boot"
BTRFS_OPTS="defaults,noatime,compress=zstd"
LOG_FILE="install.log"

# Usuário e configurações personalizáveis
USERNAME="jose"
HOSTNAME="arch"
TIMEZONE="America/Fortaleza"
LOCALE="pt_BR.UTF-8"

# Pacotes essenciais
PACOTES_BASE="base linux linux-firmware nano base-devel intel-ucode networkmanager network-manager-applet bash-completion linux-headers"
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
AMD_DRIVER_PACKAGES=(
  mesa lib32-mesa
  vulkan-radeon lib32-vulkan-radeon
  libva-mesa-driver lib32-libva-mesa-driver
  mesa-vdpau lib32-mesa-vdpau
  vulkan-icd-loader lib32-vulkan-icd-loader
  vulkan-mesa-layers
)
PACOTES_ESSENCIAIS=(
  wl-clipboard yazi rg fd ffmpeg unzip unrar 7zip jq poppler zoxide resvg imagemagick npm fwupd fzf
  ttf-nerd-fonts-symbols inter-font noto-fonts ttf-jetbrains-mono-nerd plymouth neovim rclone fastfetch
  htop btop ncdu virt-manager qemu-full ebtables dnsmasq edk2-ovmf spice-vdagent firewalld cryfs
  pacman-contrib pacutils expac less ksystemlog rsync sshfs go docker docker-compose cronie
)

# Cores
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ===============================
# FUNÇÕES
# ===============================
msg() { echo -e "${BLUE}==>${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}!${RESET} $1"; }
error() { echo -e "${RED}✗${RESET} $1" >&2; exit 1; }
check_command() {
  if [ $? -ne 0 ]; then
    echo -e "${RED}Erro ao executar: $1${RESET}"
    exit 1
  else
    echo -e "${GREEN}Sucesso: $1${RESET}"
  fi
}

# ===============================
# LOG
# ===============================
exec > >(tee -ia "$LOG_FILE") 2>&1

# ===============================
# VERIFICAR ROOT
# ===============================
[[ $EUID -ne 0 ]] && error "Execute como root."

# ===============================
# AJUSTES DE IDIOMA E TECLADO
# ===============================
msg "Ajustando idioma para pt_BR.UTF-8..."
grep -q "pt_BR.UTF-8 UTF-8" /etc/locale.gen || echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
export LANG=pt_BR.UTF-8

# ===============================
# RELÓGIO
# ===============================
msg "Ativando sincronização de tempo..."
timedatectl set-ntp true

# ===============================
# LISTAR DISCOS E SELECIONAR
# ===============================
msg "Discos disponíveis:"
mapfile -t discos < <(lsblk -d -o NAME,SIZE,MODEL | grep -vE "loop|sr0|zram" | tail -n +2)
for i in "${!discos[@]}"; do
    echo "$((i + 1))) ${discos[$i]}"
done
read -p "Digite o número do disco para instalar o sistema: " num_disco
if ! [[ "$num_disco" =~ ^[0-9]+$ ]] || [ "$num_disco" -lt 1 ] || [ "$num_disco" -gt "${#discos[@]}" ]; then
    error "Número inválido!"
fi
DISCO_NAME=$(echo "${discos[$((num_disco - 1))]}" | awk '{print $1}')
DISCO="/dev/$DISCO_NAME"
warn "Todos os dados em $DISCO serão apagados!"
read -n1 -r -p "Deseja continuar e formatar automaticamente? (s/n): " confirm
echo
[[ "$confirm" != "s" ]] && error "Operação cancelada."

# ===============================
# PARTICIONAMENTO AUTOMÁTICO
# ===============================
msg "Particionando disco: $DISCO"
parted -s "$DISCO" mklabel gpt
parted -s "$DISCO" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DISCO" set 1 esp on
parted -s "$DISCO" mkpart primary btrfs 1025MiB 100%
particao_boot="${DISCO}1"
particao_raiz="${DISCO}2"

# ===============================
# FORMATAR PARTIÇÕES
# ===============================
msg "Formatando partições..."
mkfs.fat -F32 "$particao_boot" || error "Erro ao formatar boot"
wipefs -a "$particao_raiz"
mkfs.btrfs -f "$particao_raiz" || error "Erro ao formatar raiz"

# ===============================
# CRIAR SUBVOLUMES BTRFS
# ===============================
msg "Criando subvolumes..."
mkdir -p "$MOUNT_DIR"
mount "$particao_raiz" "$MOUNT_DIR"
btrfs subvolume create "$MOUNT_DIR/@root"
btrfs subvolume create "$MOUNT_DIR/@home"
umount "$MOUNT_DIR"

# ===============================
# MONTAR SISTEMA DE ARQUIVOS
# ===============================
msg "Montando sistema de arquivos..."
mount -o "$BTRFS_OPTS,subvol=@root" "$particao_raiz" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"/{home,boot}
mount -o "$BTRFS_OPTS,subvol=@home" "$particao_raiz" "$MOUNT_DIR/home"
mount "$particao_boot" "$BOOT_DIR"

# ===============================
# INSTALAR SISTEMA BASE
# ===============================
msg "Instalando pacotes base..."
pacstrap -K "$MOUNT_DIR" $PACOTES_BASE || error "Erro no pacstrap"

# ===============================
# FSTAB
# ===============================
msg "Gerando fstab..."
genfstab -U "$MOUNT_DIR" >> "$MOUNT_DIR/etc/fstab"

# ===============================
# ENTRAR NO CHROOT E CONTINUAR INSTALAÇÃO
# ===============================
msg "Entrando no chroot para continuar a instalação..."

arch-chroot "$MOUNT_DIR" /bin/bash -e <<'EOC'

# Variáveis
USERNAME="jose"
HOSTNAME="arch"
TIMEZONE="America/Fortaleza"
LOCALE="pt_BR.UTF-8"
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
AMD_DRIVER_PACKAGES=(
  mesa lib32-mesa
  vulkan-radeon lib32-vulkan-radeon
  libva-mesa-driver lib32-libva-mesa-driver
  mesa-vdpau lib32-mesa-vdpau
  vulkan-icd-loader lib32-vulkan-icd-loader
  vulkan-mesa-layers
)
PACOTES_ESSENCIAIS=(
  wl-clipboard yazi fd ffmpeg unzip unrar 7zip jq poppler zoxide imagemagick npm fwupd fzf
  ttf-nerd-fonts-symbols inter-font noto-fonts ttf-jetbrains-mono-nerd plymouth neovim rclone fastfetch
  htop btop ncdu virt-manager qemu-full ebtables dnsmasq edk2-ovmf spice-vdagent firewalld cryfs
  pacman-contrib pacutils expac less ksystemlog rsync sshfs go docker docker-compose cronie
)
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"
check_command() {
  if [ $? -ne 0 ]; then
    echo -e "${RED}Erro ao executar: $1${RESET}"
    exit 1
  else
    echo -e "${GREEN}Sucesso: $1${RESET}"
  fi
}

echo -e "${YELLOW}>> Configurando o fuso horário...${RESET}"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
check_command "Configurar timezone"
hwclock --systohc
check_command "Sincronizar hwclock"

echo -e "${YELLOW}>> Configurando locale...${RESET}"
sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
check_command "Ativar locale $LOCALE"
locale-gen
check_command "Gerar locale"
echo "LANG=$LOCALE" > /etc/locale.conf
check_command "Definir LANG"

echo -e "${YELLOW}>> Configurando hostname e hosts...${RESET}"
echo "$HOSTNAME" > /etc/hostname
check_command "Definir hostname"
cat <<EOF > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
EOF
check_command "Criar /etc/hosts"

echo -e "${YELLOW}>> Instalando pacotes essenciais...${RESET}"
pacman -S --needed --noconfirm "${ESSENTIAL_PACKAGES[@]}"
check_command "Instalação de pacotes essenciais"

echo -e "${YELLOW}>> Gerando initramfs...${RESET}"
mkinitcpio -P
check_command "Gerar initramfs"

echo -e "${YELLOW}>> Defina a senha do root:${RESET}"
until passwd; do
  echo "Tente novamente para definir a senha do root."
done
check_command "Definir senha root"

echo -e "${YELLOW}>> Habilitando multilib e ajustes do pacman.conf...${RESET}"
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
grep -q '^ParallelDownloads = 5' /etc/pacman.conf && sed -i '/^ParallelDownloads = 5/a ILoveCandy' /etc/pacman.conf
check_command "Configurações do pacman.conf"

echo -e "${YELLOW}>> Atualizando sistema...${RESET}"
pacman -Syu --noconfirm
check_command "Atualização do sistema"

echo -e "${YELLOW}>> Habilitando serviços bluetooth e NetworkManager...${RESET}"
systemctl enable bluetooth.service
check_command "Habilitar bluetooth.service"
systemctl enable NetworkManager
check_command "Habilitar NetworkManager"

echo -e "${YELLOW}>> Instalando e configurando systemd-boot...${RESET}"
bootctl install
check_command "bootctl install"
cat <<EOF > /boot/loader/loader.conf
default  arch.conf
timeout  3
console-mode auto
editor   no
EOF
check_command "Criar /boot/loader/loader.conf"
PARTUUID_RAIZ=$(findmnt -no PARTUUID /)
check_command "Obter PARTUUID da partição raiz"
cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID_RAIZ rw quiet splash
EOF
check_command "Criar /boot/loader/entries/arch.conf"
echo -e "${GREEN}>> systemd-boot configurado com sucesso.${RESET}"

echo -e "${YELLOW}>> Instalando drivers AMD...${RESET}"
pacman -S --needed --noconfirm "${AMD_DRIVER_PACKAGES[@]}"
check_command "Instalação de drivers AMD"

echo -e "${YELLOW}>> Criando usuário $USERNAME...${RESET}"
useradd -mG wheel "$USERNAME"
check_command "Criar usuário $USERNAME"
passwd "$USERNAME"
check_command "Definir senha para $USERNAME"
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
check_command "Permissões sudo para $USERNAME"

echo -e "${YELLOW}>> Instalando pacotes adicionais...${RESET}"
pacman -S --needed --noconfirm "${PACOTES_ESSENCIAIS[@]}"
check_command "Instalação dos pacotes essenciais"

sudo sed -i '/^HOOKS=/ s/\(base udev\)/\1 plymouth/' /etc/mkinitcpio.conf
check_command "Adição do plymouth aos HOOKS"
sudo mkinitcpio -p linux
check_command "Atualização do mkinitcpio"

systemctl enable --now libvirtd.service
check_command "Ativação do libvirtd"
systemctl enable --now firewalld.service
check_command "Ativação do firewalld"
systemctl enable --now cronie.service
check_command "Ativação do cronie"
systemctl enable --now docker.socket
systemctl enable --now docker.service
check_command "Ativação do docker"

echo ">> Pulei a instalação do yay (AUR helper) porque não é possível instalar AUR como root/chroot."
echo ">> Após o reboot, logue como $USERNAME e rode:"
echo "   git clone https://aur.archlinux.org/yay.git"
echo "   cd yay && makepkg -si"

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

touch /swapfile
chattr +C /swapfile
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

systemctl daemon-reexec

cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<EOF
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

sysctl --system

systemctl enable --now systemd-timesyncd.service

usermod -aG docker "$USERNAME"
check_command "Adicionar $USERNAME ao grupo docker"
usermod -aG libvirt "$USERNAME"
check_command "Adicionar $USERNAME ao grupo libvirt"

echo ""
read -n 1 -p "Instalação concluída. Deseja reiniciar o sistema agora? (s/n): " resposta
echo ""
if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "Reiniciando o sistema..."
    reboot
else
    echo "Reinicialização cancelada. Reinicie manualmente para aplicar as alterações."
fi

EOC

cp instalar_yay.sh "$MOUNT_DIR/home/$USERNAME/"
chown $USERNAME:$USERNAME "$MOUNT_DIR/home/$USERNAME/instalar_yay.sh"
chmod +x "$MOUNT_DIR/home/$USERNAME/instalar_yay.sh"

success "Instalação base e configuração principal concluída!"
