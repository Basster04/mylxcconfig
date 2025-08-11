# mylxcconfig
Configuration auto de mes LXC Proxmox.
------------------------------------------------------------------------------
Dans "lx-packages" identifier les paquets à installer.  

Va ajouter le dossier d'échange avec le PVE 1 ou 2 pour automatiser le partage de fichier hôte ou réseau. Dossier hôte monté "/mnt/Echanges". 
Configuration du fstab du pve:
```bash
//*****/Echanges   /mnt/Echanges  cifs    credentials=/***/smbcredentials,_netdev,uid=100000,gid=100000,file_mode=0660,dir_mode=0770,iocharset=utf8,vers=3.0   0       0
```

Ajoute la clé .ssh/lxc.pub si disponible sur le PVE pour futur connexions. Pour ajouter la clé native du pve:  
cp .ssh/id_rsa.pub .ssh/lxc.pub  

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Basster04/mylxcconfig/main/custom-all-templates.sh)"
```
  

Configuration auto d'une VM
------------------------------------------------------------------------------
