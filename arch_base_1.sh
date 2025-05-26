#!/bin/bash
set -e

# ===============================
# VARIÁVEIS
# ===============================
MOUNT_DIR="/mnt"
# ALTERADO: Partição EFI montada diretamente em /boot para systemd-boot
BOOT_DIR="$MOUNT_DIR/boot"
BTRFS_OPTS="defaults,noatime,compress=zstd"

# Pacotes essenciais
# REMOVIDO: grub e efibootmgr
PACOTES_BASE="base linux linux-firmware nano base-devel intel-ucode networkmanager network-manager-applet bash-completion linux-headers"

# Scripts que serão copiados para o chroot
SCRIPTS=("arch_part2.sh" "arch_part3.sh") # Ambos precisam ser copiados

# Log
LOG_FILE="install.log"
exec > >(tee -ia "$LOG_FILE") 2>&1

# Cores
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ===============================
# FUNÇÃO DE MENSAGEM
# ===============================
msg() { echo -e "${BLUE}==>${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}!${RESET} $1"; }
error() { echo -e "${RED}✗${RESET} $1" >&2; exit 1; }

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

# Ajusta numeração de entrada (1-based para 0-based index)
if ! [[ "$num_disco" =~ ^[0-9]+$ ]] || [ "$num_disco" -lt 1 ] || [ "$num_disco" -gt "${#discos[@]}" ]; then
    error "Número inválido!"
fi

# Extrair somente o nome do dispositivo (primeira coluna)
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
# ALTERADO: A partição boot (EFI) é montada em /boot
mkdir -p "$MOUNT_DIR"/{home,boot}
mount -o "$BTRFS_OPTS,subvol=@home" "$particao_raiz" "$MOUNT_DIR/home"
mount "$particao_boot" "$BOOT_DIR" # Agora $BOOT_DIR é /mnt/boot

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
# COPIAR SCRIPTS E CHROOT
# ===============================
msg "Copiando scripts para o chroot..."
for script in "${SCRIPTS[@]}"; do
  [[ -f "$script" ]] || error "Script $script não encontrado!"
  cp "$script" "$MOUNT_DIR/" || error "Erro ao copiar $script!"
done

msg "Entrando no chroot para continuar a instalação..."
# Chama o primeiro script (arch_part2.sh) dentro do chroot.
# arch_part2.sh será responsável por chamar arch_part3.sh e passar o USERNAME.
arch-chroot "$MOUNT_DIR" /bin/bash "/${SCRIPTS[0]}" || error "Erro no chroot ao executar arch_part2.sh"

success "Instalação base e configuração principal concluída!"
