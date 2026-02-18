# Ansible Vault Dynamic Secrets Manager

> **Gestion dynamique et sécurisée des secrets Ansible pour orchestrations d'infrastructure**

## 🎯 Qu'est-ce que ce projet ?

Un système de **gestion de secrets chiffrés** pour Ansible qui permet de :
- ✅ **Charger, auto-générer et persister** des secrets dans Ansible Vault
- ✅ **Fusionner des sources externes** (K8s, APIs) directement dans le vault
- ✅ **Garantir l'atomicité** : pas de secrets en clair sur disque, verrous + tmpfs
- ✅ **Automatiser les cas complexes** : pré-génération, mutation, rotation

### Cas d'usage typiques

**1. Déploiement simple** → Auto-générer 10 mots de passe de base de données
```yaml
vault_autogen_spec:
  - { kind: scalar, path: "db_root_password", generate: "password", length: 32 }
  - { kind: scalar, path: "db_app_password", generate: "password", length: 32 }
```

**2. Déploiement avancé** → Récupérer tokens depuis K8s, ajouter tokens générés, persister tout
```yaml
# Pre-task: Charger vault
# Main-task: Récupérer token Traefik depuis kubectl
# Post-task: Fusionner + Persister (vault_mutator)
```

**3. Rotation dynamique** → Forcer la régénération d'un secret en production
```yaml
vault_autogen_spec:
  - { kind: scalar, path: "old_secret", generate: "password", override: true }
```

---

## 🏗️ Architecture

### Les 3 rôles atomiques

```
vault_loader
    ↓
  [Charge ou crée le vault Ansible chiffré]
  [Auto-chiffrage si plaintext]
    ↓
vault_autogen
    ↓
  [Génère secrets manquants selon spec YAML]
  [Supporte: scalars, listes KV, override]
    ↓
vault_mutator
    ↓
  [Persiste atomiquement dans le vault]
  [tmpfs → chiffrement → lock → atomic move]
```

### Flux complet dans un playbook

```yaml
- hosts: localhost
  vars:
    vault_autogen_spec:
      - { kind: scalar, path: "app_password", generate: "password" }

  pre_tasks:
    - include_role: { name: vault_loader }       # Load/init vault
    - include_role: { name: vault_autogen }      # Generate missing secrets

  tasks:
    - name: Deploy app with secrets
      # vault_data.app_password disponible ici

  post_tasks:
    - include_role: { name: vault_mutator }      # Persist mutations
```

---

## 🔐 Sécurité

### Principes appliqués

| Principe | Implémentation |
|----------|-----------------|
| **Pas de plaintext** | Secrets uniquement en tmpfs (`/dev/shm`), jamais sur disque |
| **Chiffrement fort** | Ansible Vault AES-256-CBC |
| **Atomicité** | Verrous POSIX (flock) + atomic `install` command |
| **Permissions** | Fichiers vault 0600, tmpfs séparation user/group |
| **Audit** | `no_log` sur tâches sensibles, debug traçable |
| **Auto-cleanup** | Suppression tmpfs après usage |

### Garanties d'intégrité

```bash
# 1. Créer clear YAML en tmpfs
echo "key: value" > /dev/shm/tmp.yml

# 2. Chiffrer vers tmpfs
ansible-vault encrypt /dev/shm/tmp.yml --output /dev/shm/tmp.vault

# 3. Acquérir lock POSIX
flock -x /var/lock/ansible-vault.lock

# 4. Atomic move (install = atomic)
install -m 0600 /dev/shm/tmp.vault /path/to/vault.yml

# 5. Nettoyer tmpfs
rm /dev/shm/tmp.* /dev/shm/tmp.vault
```

---

## 🔐 Architecture Interne & Sécurité Avancée

### 1. Tmpfs vs Disque : Pourquoi `/dev/shm` ?

**Le problème traditionnel** :
```bash
# ❌ Mauvais : Secret écrit sur disque (SSD/HDD)
echo "secret_password" > /tmp/secret.txt
# Même après rm, les données restent sur disque (forensic recovery possible)
```

**Notre approche - Tmpfs** :
```bash
# ✅ Bon : Secret en RAM uniquement
echo "secret_password" > /dev/shm/secret.txt
# Ram est effacée à chaque redémarrage ou fin de processus
# Aucune trace sur disque persistant
```

**Avantage de `/dev/shm`** :
- ✅ **RAM-backed** : Données en mémoire vive, pas sur disque
- ✅ **Isolation processus** : Seul l'utilisateur propriétaire peut lire
- ✅ **Auto-cleanup** : Supprimé automatiquement au reboot ou `rm`
- ✅ **Performance** : Lecture/écriture ultra-rapide (pas d'I/O disque)
- ✅ **Sécurité forensique** : Zéro trace après destruction

**Impact dans notre workflow** :
```
1. Charger vault.yml (chiffré) depuis disque
2. Déchiffrer UNIQUEMENT EN MÉMOIRE (tmpfs)
3. Manipuler vault_data en RAM (jamais écrit sur disque en clair)
4. Re-chiffrer en tmpfs
5. Atomic move vers disque (LE SEUL MOMENT où c'est chiffré sur disque)
6. Nettoyer tmpfs → tous les secrets en clair disparaissent
```

---

### 2. Sérialisation YAML Chiffrée : Le Flow Exact

**Étape 1 : Créer clear YAML en tmpfs**
```bash
# vault_data en mémoire Ansible :
vault_data:
  db_password: "xK9jF2mL4pQ1..."
  api_key: "aB8cD5eF3gH6..."

# Convertir en YAML clair → tmpfs (JAMAIS sur disque persistant)
/dev/shm/tmp_RANDOM.yml:
---
db_password: xK9jF2mL4pQ1...
api_key: aB8cD5eF3gH6...
```

**Étape 2 : Chiffrer en tmpfs**
```bash
# Exécuter : ansible-vault encrypt
INPUT:  /dev/shm/tmp_RANDOM.yml (clair, en RAM)
OUTPUT: /dev/shm/tmp_RANDOM.vault (chiffré, en RAM)

# Résultat (format Ansible Vault) :
/dev/shm/tmp_RANDOM.vault:
$ANSIBLE_VAULT;1.1;aes256;default
62643533323264666162656430653665383036386635336333363163346136616262336330
63316337336630663537373834376635653965373437356435366665663763610a313430383
639656234316535313066353938633337306236396665346263386565616163616461633330
[... more encrypted hex ...]
```

**Étape 3 : Acquérir verrou POSIX**
```bash
# Avant de modifier vault.yml, obtenir un lock exclusif
LOCK="/var/lock/ansible-vault.lock"
exec 9>"$LOCK"           # Ouvrir FD 9 sur le fichier lock
flock -x 9               # Acquérir lock EXCLUSIF (bloque autres processus)

# Maintenant SEUL ce processus peut modifier vault.yml
```

**Étape 4 : Atomic Move**
```bash
# Utiliser `install` = atomic rename (garantie POSIX)
install -m 0600 /dev/shm/tmp_RANDOM.vault /path/to/vault.yml

# Pourquoi `install` et pas `mv` ?
# - install = crée un nouveau fichier PUIS rename (atomic)
# - mv seul = risque de corruption si interrompu
# - Résultat : vault.yml remplacé de façon atomique, jamais corrompu
```

**Étape 5 : Nettoyer tmpfs**
```bash
# Libérer lock
flock -u 9
exec 9>&-

# Détruire fichiers temporaires
rm -f /dev/shm/tmp_RANDOM.yml
rm -f /dev/shm/tmp_RANDOM.vault

# Résultat : Aucune trace de secrets en clair sur disque
```

---

### 3. Isolation Mémoire : Comment `vault_data` est Protégée

**En mémoire Ansible (processus isolé)** :
```yaml
# Pre-tasks : vault_loader charge en mémoire
tasks:
  - include_role: { name: vault_loader }
    # Maintenant vault_data existe dans ce processus Ansible uniquement
    # Système d'exploitation = isolation processus (protégée par permissions Unix)

  - include_role: { name: vault_autogen }
    # vault_data modifiée EN MÉMOIRE (pas écrite sur disque)
    # Si 2 playbooks s'exécutent en parallèle :
    #   - Processus A : vault_data isolée en RAM du processus A
    #   - Processus B : vault_data isolée en RAM du processus B
    #   - Aucun conflit, chacun manipule sa propre copie

  - debug: var=vault_data
    # ⚠️ ATTENTION : Afficheur vault_data brute = secrets en clair dans les logs !
    # C'est pourquoi on utilise no_log: true sur les tâches sensibles

  - include_role: { name: vault_mutator }
    # Seul ce rôle ÉCRIT sur disque (et uniquement chiffré)
```

**Isolation processus = Protection du SE** :
```bash
# Deux playbooks en parallèle
ansible-playbook deploy1.yml &    # PID 1234
ansible-playbook deploy2.yml &    # PID 5678

# Mémoire du SE :
/proc/1234/fd/3 → /dev/shm/tmp_1234.yml (processus 1234 seul)
/proc/5678/fd/3 → /dev/shm/tmp_5678.yml (processus 5678 seul)

# Même si PID 5678 tente de lire /proc/1234/fd/3 → Permission denied
```

**`no_log: true` = Protection des logs** :
```yaml
- name: Sensitive task
  set_fact:
    vault_data: "{{ vault_data | combine({...}) }}"
  no_log: true  # ⚠️ Ne pas logger cette tâche

# Logs Ansible (fichier ou stdout) :
# SANS no_log: "vault_data: {db_password: 'xK9jF2mL4pQ1...', api_key: ...}"
# AVEC no_log:  "*** ENCRYPTED ***" ou omission complète
```

---

### 4. Lock POSIX + Atomic Move : Race Conditions Impossibles

**Scénario sans lock (❌ MAUVAIS)** :
```
Processus A                          Processus B
───────────────────────────────────────────────────────
Lire vault.yml (v1)
                                    Lire vault.yml (v1)
Modifier (add db_pass)
Écrire vault.yml (v2: db_pass)
                                    Modifier (add api_key)
                                    Écrire vault.yml (v3: LOST db_pass!)
                                    ❌ db_pass perdu = corruption

Résultat : vault.yml contient UNIQUEMENT api_key, db_pass disparu
```

**Avec lock POSIX (✅ BON)** :
```
Processus A                          Processus B
───────────────────────────────────────────────────────
flock -x /var/lock/ansible-vault.lock
                                    flock -x /var/lock/ansible-vault.lock
                                    (BLOQUÉ, attend A)
Lire vault.yml (v1)
Modifier (add db_pass)
Écrire vault.yml (v2: db_pass)
flock -u /var/lock/ansible-vault.lock  (LIBÈRE le lock)
                                    flock acquired (B continue)
                                    Lire vault.yml (v2: contient db_pass!)
                                    Modifier (add api_key)
                                    Écrire vault.yml (v3: db_pass + api_key)
                                    flock -u

Résultat : vault.yml contient TOUT (db_pass + api_key) ✅
```

**Atomic move = Jamais de fichier corrompu** :
```bash
# Sans atomic move (❌ risqué)
mv /dev/shm/tmp.vault /path/to/vault.yml
# Si interrompu à mi-chemin = fichier vault.yml partiellement écrit

# Avec atomic move (✅ sûr)
install -m 0600 /dev/shm/tmp.vault /path/to/vault.yml
# `install` garantit POSIX : soit vault.yml est ENTIÈREMENT ancien, soit ENTIÈREMENT nouveau
# Jamais d'état intermédiaire
```

**Garantie totale** :
```bash
# Combinaison : Lock + Atomic move + Tmpfs
1. Lock exclusif = seul processus accède à vault.yml
2. Tmpfs = manipulations en RAM, ultra-rapide
3. Atomic install = vault.yml jamais corrompu
4. Tmpfs cleanup = zéro trace

Résultat : N playbooks en parallèle = tous les changements TOUS persisten correctement
```

---

### 5. Cleanup Mémoire : Zéro Trace Après Mutation

**Logs Ansible (protection `no_log`)** :
```yaml
- name: Persist vault
  block:
    - include_role: { name: vault_mutator }
  # Les tâches inside vault_mutator ont `no_log: false`
  # MAIS les infos sensibles (vault_data content) ne sortent jamais via `set_fact` avec no_log

# Logs visibles :
# "Create tmp clear YAML in /dev/shm" ✅ (chemin tmpfs OK, pas de contenu)
# "Encrypt to tmpenc" ✅ (chiffrement OK)
# "Atomic move under lock" ✅ (move OK)
# "Cleanup tmp files" ✅ (rm OK)

# Logs cachés :
# Contenu vault_data ❌ (jamais loggé)
# Fichiers tmpfs chemin absolu ❌ (nommage aléatoire)
```

**Destruction physique de tmpfs** :
```bash
# Après vault_mutator :
rm -f /dev/shm/tmp_*.yml
rm -f /dev/shm/tmp_*.vault

# Vérifier : rien sur disque
ls -la ansible/group_vars/all/
# vault.yml (CHIFFRÉ uniquement) ✅

# Vérifier : rien en tmpfs
ls -la /dev/shm/
# (pas de tmp_* files) ✅

# Secrets perdus physiquement :
# - RAM tmpfs → détruite
# - Mémoire processus Ansible → isolée (autre processus ne peut pas accéder)
# - Logs → `no_log` protège
```

**Timeline complète d'une mutation** :
```
T=0s   : vault_loader lit vault.yml (chiffré) depuis disque
T=1s   : Déchiffre → tmpfs (secrets EN CLAIR, mais RAM)
T=2s   : vault_autogen modifie vault_data en mémoire
T=3s   : vault_mutator acquiert lock POSIX
T=4s   : Crée tmp clear YAML en tmpfs
T=5s   : Chiffre en tmpfs
T=6s   : Atomic move → vault.yml chiffré sur disque
T=7s   : Libère lock
T=8s   : Nettoie tmpfs (rm -f tmp_*)
T=9s   : Processus Ansible termine

Trace restante sur disque : UNIQUEMENT vault.yml (100% chiffré) ✅
Trace en RAM : Aucune (processus terminé) ✅
Trace en logs : Aucune (no_log protège) ✅
```

---

### Diagram : Flux Complet Sécurisé

```
┌─────────────────────────────────────────────────────────┐
│ PLAYBOOK ANSIBLE                                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  PRE-TASKS:                                             │
│  ┌──────────────────────────────────────────────────┐   │
│  │ vault_loader                                     │   │
│  │ ├─ Lire vault.yml (CHIFFRÉ) disque               │   │
│  │ ├─ Déchiffrer → /dev/shm (RAM tmpfs)             │   │
│  │ └─ Parser YAML → vault_data (mémoire)            │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │ vault_autogen                                    │   │
│  │ ├─ Lire vault_autogen_spec (déclaration)         │   │
│  │ ├─ Générer passwords manquants                   │   │
│  │ └─ Modifier vault_data EN MÉMOIRE                │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  MAIN-TASKS:                                            │
│  (vault_data maintenant disponible pour le playbook)    │
│                                                         │
│  POST-TASKS:                                            │
│  ┌──────────────────────────────────────────────────┐   │
│  │ vault_mutator                                    │   │
│  │ ├─ Acquérir lock POSIX (/var/lock/...)           │   │
│  │ ├─ Créer tmp clear YAML en /dev/shm              │   │
│  │ ├─ Chiffrer → tmp encrypted en /dev/shm          │   │
│  │ ├─ Atomic move → vault.yml (disque, CHIFFRÉ)     │   │
│  │ ├─ Libérer lock                                  │   │
│  │ └─ Nettoyer /dev/shm (rm -f tmp_*)               │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘

TRACE RESTANTE:
  ✅ vault.yml = 100% chiffré AES-256
  ✅ Logs = no_log protection
  ❌ Aucun secret en clair sur disque
  ❌ Aucun fichier tmpfs restant
```

---

## 📋 Installation & Setup

### Pré-requis
```bash
ansible                # >= 2.10
openssl                # Chiffrement Vault
yq                     # Parsing YAML (optionnel, pour debug)
```

### Structure minimale
```
project/
├── ansible/
│   ├── playbooks/
│   │   ├── vault_mutator_autogen_test.yml    (test simple)
│   │   ├── minio.yml                         (exemple: MinIO)
│   │   └── traefik.yml                       (exemple: Traefik + K8s)
│   ├── group_vars/all/vault.yml              (chiffré, gitignoré)
│   ├── .vault-pass                           (password file, gitignoré)
│   └── roles/
│       ├── vault_loader/
│       ├── vault_autogen/
│       └── vault_mutator/
├── ansible.cfg
└── Makefile
```

### ansible.cfg minimal
```ini
[defaults]
roles_path = ./ansible/roles
vault_password_file = ansible/.vault-pass
stdout_callback = yaml
```

### Initialisation
```bash
# 1. Créer password file (JAMAIS en Git)
echo "my-secure-password" > ansible/.vault-pass
chmod 600 ansible/.vault-pass
echo "ansible/.vault-pass" >> .gitignore

# 2. Initialiser vault vide
mkdir -p ansible/group_vars/all
touch ansible/group_vars/all/vault.yml

# 3. Lancer test
make vault_mutator_autogen_test
```

---

## 📚 Utilisation

### Exemple 1 : Auto-génération simple
```yaml
# playbook: deploy.yml
- hosts: localhost
  vars:
    vault_autogen_spec:
      - { kind: scalar, path: "db_password", generate: "password", length: 32 }
      - { kind: scalar, path: "api_key", generate: "password", length: 48, chars: "ascii_letters,digits" }
      - { kind: scalar, path: "admin_user", default: "admin" }

  pre_tasks:
    - include_role: { name: vault_loader }
    - include_role: { name: vault_autogen }

  tasks:
    - name: Output generated secrets (demo only)
      debug:
        msg:
          db_password: "{{ vault_data.db_password | regex_replace('.*', '<hidden>') }}"
          api_key: "{{ vault_data.api_key | regex_replace('.*', '<hidden>') }}"

  post_tasks:
    - include_role: { name: vault_mutator }
```

**Résultat** : Vault contient maintenant `db_password`, `api_key`, `admin_user`.

---

### Exemple 2 : Listes KV (Key-Value)
```yaml
vault_autogen_spec:
  - kind: kv_list
    var: "database_users"
    keys: ["root", "app", "backup"]
    value: { generate: "password", length: 24 }
```

**Structure générée**:
```yaml
database_users:
  - key: root
    value: "xK9jF2mL4pQ1..."
  - key: app
    value: "aB8cD5eF3gH6..."
  - key: backup
    value: "iJ2kL9mN6oP1..."
```

---

### Exemple 3 : Fusion K8s + Vault (Traefik)
```yaml
- hosts: localhost
  pre_tasks:
    # 1. Charger vault
    - include_role: { name: vault_loader }
    - include_role: { name: vault_autogen }

    # 2. Récupérer secrets depuis K8s
    - name: Get Traefik token from K8s
      shell: kubectl get secret traefik-token -o json | jq -r '.data.token | @base64d'
      register: k8s_traefik_token

    # 3. Ajouter à vault_data (en mémoire)
    - name: Inject K8s secret into vault
      set_fact:
        vault_data: "{{ vault_data | combine({'traefik_token_prod': k8s_traefik_token.stdout}) }}"
        vault_data_changed: true

  tasks:
    - include_role: { name: traefik }

  post_tasks:
    # 4. Persister mutations (traefik_token_prod)
    - include_role: { name: vault_mutator }
      when: vault_data_changed | default(false)
```

---

### Exemple 4 : Rotation de secrets
```yaml
# Ajouter temporairement override: true
vault_autogen_spec:
  - { kind: scalar, path: "old_api_key", generate: "password", override: true }
```

**Effet** :
- ✅ Ancien secret écrasé
- ✅ Nouveau secret généré
- ✅ Persisté dans vault
- ✅ Ancien secret perdu (pas d'historique)

---

## 🚀 Cas d'usage avancés

### MinIO Deployment (playbooks/minio.yml)
**Pattern**: Pré-générer N secrets + ajouter dynamiquement des tokens post-déploiement

```yaml
- hosts: minio
  vars:
    vault_autogen_spec:
      - { kind: scalar, path: "vault_minio_root_password", generate: "password" }
      - { kind: scalar, path: "vault_minio_longhorn_back_password", generate: "password" }
      # ... 8 autres passwords ...

  pre_tasks:
    - include_role: { name: vault_loader }
    - include_role: { name: vault_autogen }
    - include_role: { name: vault_mutator }

  roles:
    - minio  # Déploiement MinIO (utilise vault_data)

  post_tasks:
    # Générer dynamiquement un API token post-déploiement
    - name: Generate API token after MinIO is up
      set_fact:
        vault_data: "{{ vault_data | combine({'minio_api_token': lookup('password', '/dev/null', length=48)}) }}"
        vault_data_changed: true

    # Re-persister avec le nouveau token
    - include_role: { name: vault_mutator }
      when: vault_data_changed | default(false)
```

**Avantages** :
- ✅ Tous les secrets en un seul endroit
- ✅ Workflow déploiement → génération → persistence transparent
- ✅ Récupération tokens post-déploiement automatisée

---

### Traefik + Kubernetes (playbooks/traefik.yml)
**Pattern**: Fusionner secrets K8s + generer secrets manquants + persister

```yaml
- hosts: traefiks
  pre_tasks:
    - include_role: { name: vault_loader }
    - include_role: { name: vault_autogen }

    # Récupérer tokens depuis K8s clusters
    - name: Get Traefik external token from each cluster
      command: kubectl --context {{ item }} get secret traefik-external-token -n kube-system -o json
      loop: "{{ traefik_clusters }}"
      register: k8s_tokens

    # Parser et injecter dans vault_data
    - name: Build tokens dict from K8s responses
      set_fact:
        traefik_tokens: >-
          {{ traefik_tokens | default({}) | combine({
               item.item: (item.stdout | from_json).data.token | b64decode
             }) }}
      loop: "{{ k8s_tokens.results }}"
      when: item.rc == 0

    # Fusionner dans vault
    - name: Inject K8s tokens into vault
      set_fact:
        vault_data: "{{ vault_data | combine({'traefik_tokens_prod': traefik_tokens}) }}"
        vault_data_changed: true

  roles:
    - traefik  # Config Traefik avec tokens

  post_tasks:
    # Persister la fusion K8s + vault_autogen
    - include_role: { name: vault_mutator }
      when: vault_data_changed | default(false)
```

**Avantages** :
- ✅ Single source of truth : vault + K8s en sync
- ✅ Récupération tokens sans intervention manuelle
- ✅ Rollback facile (reverting Git + rejeu playbook)

---

## 🧪 Tests & Debug

### Test simple (vault_mutator_autogen_test.yml)
```bash
make vault_mutator_autogen_test
```

Vérifie que les secrets ont été générés :
```bash
ansible-vault view ansible/group_vars/all/vault.yml --vault-password-file ansible/.vault-pass | yq '.vault_autogen_test1, .vault_autogen_test_kv'
```

### Debug chemins absolus
```bash
DEBUG_VAULT_PATHS=1 make vault_mutator_autogen_test
```

Affiche :
```
repo_root=/home/user/project
vault_file_abs=/home/user/project/ansible/group_vars/all/vault.yml
vault_password_file_abs=/home/user/project/ansible/.vault-pass
```

### Variables de configuration

```yaml
# Defaults (customizable)
vault_file: "ansible/group_vars/all/vault.yml"
vault_password_file: "ansible/.vault-pass"
vault_lock_dir: "/var/lock"  # ou XDG_RUNTIME_DIR si non-root

# Auto-behavior
vault_loader_encrypt_if_plaintext: true    # Auto-encrypt vault si plaintext

# Autogen defaults
vault_autogen_default_length: 64           # Longueur par défaut des passwords
vault_autogen_charset: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#!."
```

---

## ✅ Production-Readiness Checklist

| Critère | Status | Notes |
|---------|--------|-------|
| **Sécurité** | ✅ | Tmpfs, chiffrement AES-256, atomicité garantie |
| **Idempotence** | ✅ | vault_autogen ne crée que si manquant (sauf override) |
| **Robustesse** | ✅ | Auto-init, auto-encrypt, race-condition safe |
| **Scalabilité** | ✅ | Testé avec 50+ secrets, performance acceptable |
| **Auditabilité** | ✅ | Logs non-sensibles, debug activable |
| **Rotation** | ✅ | `override: true` force régénération |
| **Intégrations** | ✅ | K8s (kubectl), API standard, Git-friendly |
| **Limitations** | ⚠️ | Mono-repo (pas multi-machines), pas historique |

### Recommandations production

1. **Stockage du .vault-pass**
   - ❌ JAMAIS en Git
   - ✅ Géré par CI/CD secrets ou HashiCorp Vault
   - ✅ Copie locale avec `chmod 600`

2. **Rotation régulière**
   - Utiliser `override: true` dans spec mensuelle
   - Commiter le changement en Git
   - Rejeu playbook

3. **Backup**
   - Vault.yml = source de vérité
   - Commits Git = historique
   - Accès read-only à vault.yml sur prod

4. **Équipes**
   - 1-10 personnes : partage .vault-pass sécurisé
   - 10+ personnes : migrer vers HashiCorp Vault + plugin Ansible

---

## 🛠️ Commandes utiles

```bash
# Afficher vault (déchiffré)
make vault_show

# Chiffrer vault si plaintext
make vault_encrypt

# Déchiffrer vault (⚠️ attention)
make vault_decrypt

# Test complet autogen + mutator
make vault_mutator_autogen_test

# Debug chemins
DEBUG_VAULT_PATHS=1 make vault_mutator_autogen_test

# Commit + push (avec auto-encrypt)
make commit m="Message de commit"
```

---

## ❓ Dépannage

### "Impossible to decrypt vault"
```bash
# Vérifier que .vault-pass existe et est lisible
ls -la ansible/.vault-pass

# Vérifier contenu vault.yml
head -1 ansible/group_vars/all/vault.yml  # Doit commencer par $ANSIBLE_VAULT;
```

### "vault_data undefined"
```bash
# S'assurer que vault_loader a été exécuté avant
- include_role: { name: vault_loader }
- include_role: { name: vault_autogen }  # vault_data doit exister
```

### "Race condition on atomic move"
```bash
# Vérifier permissions lock_dir
ls -ld /var/lock  # doit être 755
ls -ld ~/.cache/ansible/locks  # si XDG_RUNTIME_DIR non-root
```

### "Secrets en plaintext sur disque"
```bash
# Jamais créer plaintext vault
# vault_loader auto-chiffre si vault_loader_encrypt_if_plaintext: true (default)

# Si déjà plaintext, chiffrer:
make vault_encrypt
```

---

## 📄 Licence & Contribution

MIT License - Libre d'usage personnel et commercial.

Développé par David Ribeiro pendant mon stage à 42 Mulhouse (2023-2024) pour orchestration infrastructure Kubernetes multi-cluster.
