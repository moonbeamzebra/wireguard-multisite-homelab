# 🚀 Homelab Checklist : GMKtec M7 Ultra (Ryzen 6850U)

Ce document est la "Recette" de déploiement pour les nœuds du **Site A (Home)** et **Site B (Cottage)** sous **Debian 13 (Trixie)**.

---

## 1. Configuration du BIOS / UEFI
*Touche `Suppr` ou `F2` au démarrage.*

| Catégorie | Paramètre | Valeur | Pourquoi ? |
| :--- | :--- | :--- | :--- |
| **CPU** | **SVM Mode** | **Enabled** | Indispensable pour la virtualisation KVM (AMD-V). |
| **Chipset** | **IOMMU** | **Enabled** | Permet l'isolation des périphériques (GPU Passthrough). |
| **Boot** | **Secure Boot** | **Disabled** | Évite les conflits avec les firmwares non-signés. |
| **Boot** | **Fast Boot** | **Disabled** | Assure la détection de l'adaptateur USB-Ethernet. |
| **Power** | **AC Power Loss** | **Power On** | Redémarrage auto après coupure (Crucial Site A). |
| **Vidéo** | **UMA Frame Buffer**| **2G ou 4G** | Mémoire dédiée au GPU pour Jellyfin (Site B). |
| **Power** | **Power Mode** | **Performance** | Empêche le bridage thermique trop agressif. |

---

## 2. Préparation du Preseed (`preseed.cfg`)
Paramètres à vérifier avant la génération de l'ISO d'installation.

### Options Kernel (GRUB)
Désactive l'IPv6 nativement et stabilise l'IOMMU pour Ryzen :
```text
d-i debian-installer/add-kernel-opts string quiet amd_iommu=on iommu=pt ipv6.disable=1