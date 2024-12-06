#!/bin/bash

# Variáveis de diretório
GDRIVE_DIR="/home/jose/Nuvem/Google Drive"
ONEDRIVE_DIR="/home/jose/Nuvem/OneDrive"
SERVIDOR_DIR="/home/jose/Nuvem/Servidor"

# Criar as pastas necessárias, caso não existam
echo "Criando pastas de montagem..."
mkdir -p "$GDRIVE_DIR"
mkdir -p "$ONEDRIVE_DIR"
mkdir -p "$SERVIDOR_DIR"

# Criar arquivos de serviço

# Serviço para o Google Drive
cat <<EOF | sudo tee /etc/systemd/system/rclone-gdrive.service
[Unit]
Description=Mount Google Drive via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount gdrive: "$GDRIVE_DIR" --vfs-cache-mode writes --allow-other
ExecStop=/bin/fusermount -u "$GDRIVE_DIR"
Restart=always
User=jose

[Install]
WantedBy=default.target
EOF

# Serviço para o OneDrive
cat <<EOF | sudo tee /etc/systemd/system/rclone-onedrive.service
[Unit]
Description=Mount OneDrive via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount onedrive: "$ONEDRIVE_DIR" --vfs-cache-mode writes --allow-other
ExecStop=/bin/fusermount -u "$ONEDRIVE_DIR"
Restart=always
User=jose

[Install]
WantedBy=default.target
EOF

# Serviço para o Servidor
cat <<EOF | sudo tee /etc/systemd/system/rclone-servidor.service
[Unit]
Description=Mount Servidor via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount servidor: "$SERVIDOR_DIR" --vfs-cache-mode writes --allow-other
ExecStop=/bin/fusermount -u "$SERVIDOR_DIR"
Restart=always
User=jose

[Install]
WantedBy=default.target
EOF

# Recarregar o systemd para reconhecer os novos serviços
echo "Recarregando o systemd..."
sudo systemctl daemon-reload

# Habilitar e iniciar os serviços
echo "Habilitando e iniciando os serviços..."
sudo systemctl enable rclone-gdrive.service
sudo systemctl start rclone-gdrive.service

sudo systemctl enable rclone-onedrive.service
sudo systemctl start rclone-onedrive.service

sudo systemctl enable rclone-servidor.service
sudo systemctl start rclone-servidor.service

echo "Pastas criadas e serviços configurados com sucesso!"
