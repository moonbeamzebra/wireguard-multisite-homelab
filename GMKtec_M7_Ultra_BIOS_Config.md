
# Configuration BIOS recommandée — GMKtec M7 Ultra  
**Modèle :** GMKtec Mini PC de jeu M7 Ultra  
**CPU :** AMD Ryzen 7 PRO 6850U (8C/16T, jusqu'à 4.70 GHz)  
**GPU :** Radeon 680M  
**RAM :** 32 Go DDR5  
**Stockage :** NVMe 1 To  
**Réseau :** Double LAN 2.5G + USB-C / USB4  
**Date de documentation :** 2026-04-26

---

## Objectif de cette configuration

Optimiser la machine pour :

- Debian 13 / Linux serveur
- KVM / libvirt
- Routeur virtualisé
- WireGuard / VPN inter-sites
- Homelab stable et performant
- Redémarrage automatique après panne de courant

---

# BIOS Tab: Main

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| Power Mode Select | Balance | Performance | Maximise la réactivité CPU pour routage, chiffrement VPN et VMs |
| Processor Type | AMD Ryzen 7 PRO 6850U | Inchangé | Information système |
| Total Memory | 32768 MB | Inchangé | Information système |
| NVMe Information | TWSC TSC3AN1T0... | Vérifié | SSD détecté correctement |
| System Language | English | English | Préférence utilisateur |
| System Date | À ajuster | Date actuelle | Important pour certificats SSL/TLS, SSH |
| System Time | À ajuster | Heure actuelle | Important pour logs système |

---

# BIOS Tab: Advanced

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| Wake On LAN | Enabled | Enabled | Permet réveil à distance |
| Auto Power On | Power Off | Power On | Redémarrage automatique après panne secteur |
| USB Boot | Enabled | Enabled | Requis pour installation via clé USB |
| CPU Configuration | Menu | Entrer | Vérifier virtualisation |
| AMD CBS | Menu | Entrer | Réglages IOMMU / PCIe |
| Intel Ethernet I226-V #1 | MAC détectée | Vérifié | Port LAN 2.5G |
| Intel Ethernet I226-V #2 | MAC détectée | Vérifié | Deuxième port LAN 2.5G |

---

# Advanced > CPU Configuration

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| PSS Support | Enabled | Enabled | Gestion énergie par l'OS |
| NX Mode | Enabled | Enabled | Protection mémoire |
| SVM Mode | Enabled | Enabled | Virtualisation AMD-V pour KVM |
| AMD SMT | Enabled | Enabled | Active les 16 threads logiques |

---

# Advanced > AMD CBS

## Sous-menus utiles

| Sous-menu | Action | Raison |
|---|---|---|
| CPU Common Options | Ignorer | Déjà couvert |
| NBIO Common Options | Entrer | Contient IOMMU |
| FCH Common Options | Plus tard | USB / SATA |
| SMU Common Options | Facultatif | Gestion puissance |

---

# Advanced > AMD CBS > NBIO Common Options

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| IOMMU | Auto | Enabled | Isolation matérielle / PCI passthrough |
| PCIe ARI Support | Auto | Auto | Laisser par défaut |
| PSPP Policy | Auto | Balanced | Évite baisse agressive du bus PCIe |

---

# BIOS Tab: Security

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| System Mode | User | Inchangé | Information |
| Secure Boot | Disabled | Disabled | Recommandé pour Linux / kernels custom |
| Secure Boot Mode | Selon BIOS | Inchangé | Aucun changement requis |

---

# BIOS Tab: Boot

| Paramètre | Valeur actuelle | Valeur cible | Raison |
|---|---|---|---|
| Setup Prompt Timeout | 2 | 5 | Plus facile d'entrer dans le BIOS |
| Boot Option #1 | USB Device | USB Device | Priorité installation Debian |
| Boot Option #2 | NVMe Windows | NVMe Debian | Deviendra Debian après install |
| Quiet Boot | Enabled | Disabled | Affiche messages POST / debug |

---

# Notes d’expert

## Timeout BIOS
Un délai de 5 secondes aide avec les claviers sans fil USB dont le dongle initialise lentement.

## Boot USB
Quand la clé Debian est branchée, le système démarre dessus. Une fois retirée, le SSD reprend la priorité.

## Windows Boot Manager
L’entrée actuelle sera remplacée automatiquement par Debian / GRUB.

## Secure Boot
Le laisser désactivé simplifie DKMS, modules réseau, virtualisation et noyaux personnalisés.

---

# Dernière étape

1. Aller à **Save & Exit**
2. Choisir **Save Changes and Reset**
3. Laisser démarrer l’installateur Debian

---

# Résultat attendu

Après redémarrage, la machine sera prête pour :

- Debian 13
- KVM / libvirt
- Open vSwitch
- VLAN internes
- Routeur virtualisé
- WireGuard site-à-site
- Homelab 24/7 fiable

---

# Validation Linux après installation

```bash
lscpu | grep Virtualization
dmesg | grep -i iommu
ip a
systemctl status libvirtd
```

---

# Statut final

**Plateforme validée pour homelab avancé.**
