# mylxcconfig
Configuration auto de mes LXC Proxmox.
------------------------------------------------------------------------------
Dans "lx-packages" identifier les paquets à installer.  

Va ajouter le dossier d'échange avec le PVE 1 ou 2 pour automatiser le partage de fichier hôte ou réseau. Dossier hôte monté "/mnt/echanges".  

Ajoute la clé .ssh/lxc.pub si disponible sur le PVE pour futur connexions. Pour ajouter la clé native du pve:  
cp .ssh/id_rsa.pub lxc.pub  

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Basster04/mylxcconfig/main/custom-all-templates.sh)"
