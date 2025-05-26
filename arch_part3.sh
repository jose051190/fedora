#!/bin/bash

# Captura o nome de usuário passado como argumento
# Este script AGORA DEVE SER CHAMADO por arch_part2.sh, passando o USERNAME
USERNAME="$1"
if [ -z "$USERNAME" ]; then
    echo "Erro: Nome de usuário não fornecido ao arch_part3.sh. Não é possível adicionar a grupos."
    exit 1 # Erro fatal se o username não for passado
fi

#-------------------------------------
# FUNÇÃO PARA VERIFICAR COMANDOS
#-------------------------------------
check_command() {
    if [ $? -ne 0 ]; then
        echo "Erro ao executar: $1"
        exit 1
    fi
}

#-------------------------------------
# INSTALAÇÃO DE PACOTES ESSENCIAIS
#-------------------------------------
PACOTES_ESSENCIAIS=(wl-clipboard yazi fd ffmpeg unzip unrar 7zip jq poppler zoxide imagemagick npm fwupd fzf ttf-nerd-fonts-symbols inter-font noto-fonts ttf-jetbrains-mono-nerd plymouth neovim rclone fastfetch htop btop ncdu virt-manager qemu-full ebtables dnsmasq edk2-ovmf spice-vdagent firewalld cryfs pacman-contrib pacutils expac less ksystemlog rsync sshfs go docker docker-compose cronie)

sudo pacman -S --needed "${PACOTES_ESSENCIAIS[@]}"
check_command "Instalação dos pacotes essenciais"

#-------------------------------------
# CONFIGURAÇÃO DO PLYMOUTH (para systemd-boot)
#-------------------------------------
# A linha 'quiet splash' já foi adicionada na entrada do systemd-boot em arch_part2.sh.
# Não precisamos modificar GRUB_CMDLINE_LINUX_DEFAULT ou rodar grub-mkconfig,
# pois não estamos usando GRUB.

# Adicionar plymouth ao vetor HOOKS em mkinitcpio.conf após base e udev
sudo sed -i '/^HOOKS=/ s/\(base udev\)/\1 plymouth/' /etc/mkinitcpio.conf
check_command "Adição do plymouth aos HOOKS"

# Atualizar mkinitcpio (regenera o initramfs com o hook do plymouth)
sudo mkinitcpio -p linux
check_command "Atualização do mkinitcpio"

#-------------------------------------
# SERVIÇOS
#-------------------------------------
# Ativar e iniciar libvirtd
sudo systemctl enable --now libvirtd.service
check_command "Ativação do libvirtd"

# Ativar e iniciar firewalld
sudo systemctl enable --now firewalld.service
check_command "Ativação do firewalld"

# Ativar e iniciar cronie
sudo systemctl enable --now cronie.service
check_command "Ativação do cronie"

# Ativar serviços do Docker
sudo systemctl enable --now docker.socket
sudo systemctl enable --now docker.service
check_command "Ativação do docker"

#-------------------------------------
# INSTALAÇÃO DO YAY (AUR HELPER)
#-------------------------------------
# Instala o Yay como o usuário normal, garantindo que as permissões e ownerships estejam corretas.
echo ">> Instalando YAY como usuário $USERNAME..."
sudo -u "$USERNAME" bash -c "
  cd /tmp/ || { echo 'Erro: Não foi possível mudar para /tmp/'; exit 1; }
  git clone https://aur.archlinux.org/yay.git || { echo 'Erro: Falha ao clonar yay.'; exit 1; }
  cd yay || { echo 'Erro: Não foi possível mudar para o diretório yay.'; exit 1; }
  makepkg -si --noconfirm || { echo 'Erro: Falha ao instalar yay com makepkg.'; exit 1; }
"
check_command "Instalação do yay"
echo ">> YAY instalado."


#-------------------------------------
# CONFIGURAÇÃO DO ZRAM E SWAPFILE
#-------------------------------------
# Criar configuração do zram-generator
sudo bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF'

# Criar arquivo de swapfile
sudo touch /swapfile
sudo chattr +C /swapfile
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Recarregar systemd (necessário para o zram-generator.conf)
sudo systemctl daemon-reexec

# Ajustar parâmetros sysctl para zram
sudo bash -c 'cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<EOF
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF'

sudo sysctl --system

#-------------------------------------
# AJUSTES FINAIS
#-------------------------------------
# Sincronizar horário
sudo systemctl enable --now systemd-timesyncd.service

# Adicionar usuário aos grupos docker e libvirt (agora usando a variável $USERNAME)
sudo usermod -aG docker "$USERNAME"
check_command "Adicionar $USERNAME ao grupo docker"
sudo usermod -aG libvirt "$USERNAME"
check_command "Adicionar $USERNAME ao grupo libvirt"

# Perguntar sobre reinicialização
read -n 1 -p "Instalação concluída. Deseja reiniciar o sistema agora? (s/n): " resposta

echo ""
if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "Reiniciando o sistema..."
    sudo reboot
else
    echo "Reinicialização cancelada. Reinicie manualmente para aplicar as alterações."
fi
