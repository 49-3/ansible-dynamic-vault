# Architecture & Design Decisions

## Overview

`ansible-vault-dynamic-secrets` est composé de 3 rôles Ansible atomiques qui travaillent ensemble pour fournir une gestion de secrets sécurisée, auditée et idempotente.

## Design Principles

### 1. Atomicité (No Partial Writes)
- **Problem**: Fichiers vault corrompus si processus interrompu
- **Solution**: Tmpfs → Chiffrement → Lock POSIX → Atomic `install`
- **Garantie**: Vault.yml est TOUJOURS soit ancien complet, soit nouveau complet

### 2. Sécurité (Zero Secrets on Disk)
- **Problem**: Secrets persistants sur SSD/HDD même après suppression
- **Solution**: Manipulations uniquement en tmpfs RAM
- **Garantie**: Aucune forensic recovery possible après nettoyage

### 3. Idempotence (Safe Re-runs)
- **Problem**: Relancer playbook ne doit pas régénérer les secrets existants
- **Solution**: `vault_autogen` crée uniquement ce qui manque (sauf `override: true`)
- **Garantie**: Playbook lancé 10 fois = même vault.yml

### 4. Auditabilité (Git-Friendly)
- **Problem**: Pas de traçabilité des changements de secrets
- **Solution**: Vault.yml en Git (chiffré), commits tracent toutes les mutations
- **Garantie**: Historique complet, rollback possible

## Rôles

### vault_loader
**Responsabilité** : Charger le vault depuis disque et le décrypter en mémoire

**Flux**:
1. Déterminer chemins absolus (repo_root, vault_file, vault_password_file)
2. Si fichier manque : créer et chiffrer {} vide
3. Détecter si vault est chiffré ou plaintext
4. Si plaintext et `vault_loader_encrypt_if_plaintext: true` : auto-chiffrer
5. Lire et parser vault YAML en mémoire (`vault_data`)

**Outputs**:
- `vault_data` : dict avec tous les secrets
- `repo_root`, `vault_file_abs`, `vault_password_file_abs` : chemins résolus

**Garanties**:
- Idempotent : appeler 2x = même résultat
- Sécurisé : secrets jamais loggés

---

### vault_autogen
**Responsabilité** : Générer les secrets manquants selon spec déclarative

**Flux**:
1. Initialiser contexte (autogen_added = [])
2. Pour chaque entry dans `vault_autogen_spec` :
   - Si `kind: scalar` : générer password ou utiliser default
   - Si `kind: kv_list` : générer liste de key-value pairs
3. Respecter `override: true` = régénération forcée

**Inputs**:
- `vault_autogen_spec` : liste déclarative des secrets à générer
- `vault_autogen_default_length` : 64 (longueur par défaut)
- `vault_autogen_charset` : caractères pour password generation

**Outputs**:
- `vault_data` : mise à jour avec nouvelles clés
- `autogen_added` : log des créations/overrides

**Garanties**:
- N'écrase jamais les existants (sauf `override: true`)
- Passwords générés aléatoirement avec `lookup('password')`
- Idempotent

---

### vault_mutator
**Responsabilité** : Persister les mutations de `vault_data` dans vault.yml de façon atomique

**Flux**:
1. Résoudre chemins absolus (comme vault_loader)
2. Acquérir lock POSIX exclusif (`flock -x`)
3. Créer tmp clear YAML en `/dev/shm`
4. Chiffrer vers tmp en `/dev/shm`
5. Atomic move (`install`) vers vault.yml (disque, chiffré)
6. Libérer lock
7. Nettoyer tmpfs

**Inputs**:
- `vault_data` (ou `vault_write_map` si custom): dict à persister
- `vault_lock_dir` : où créer le lock file (default: `/var/lock`)

**Outputs**:
- vault.yml modifié et chiffré sur disque

**Garanties**:
- Atomique : jamais de fichier partiellement écrit
- Thread-safe : lock POSIX prévient race conditions
- Secure : secrets jamais en plaintext sur disque

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PLAYBOOK EXECUTION                                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ PRE-TASKS:                                                              │
│                                                                         │
│ 1. vault_loader                                                         │
│    - Disque (vault.yml chiffré) → Mémoire Ansible (vault_data)         │
│    - Include: tasks/main.yml → set_fact vault_data                     │
│                                                                         │
│ 2. vault_autogen                                                        │
│    - Mémoire Ansible (vault_data) → Modifier avec nouvelles clés       │
│    - Include: tasks/main.yml → combine vault_data                      │
│                                                                         │
│ MAIN-TASKS: (vault_data accessible pour le playbook)                   │
│    - Utiliser vault_data.db_password, vault_data.api_key, etc.         │
│                                                                         │
│ POST-TASKS:                                                             │
│                                                                         │
│ 3. vault_mutator                                                        │
│    - Mémoire Ansible (vault_data) → Disque (vault.yml chiffré)         │
│    - Include: tasks/main.yml → atomic persist avec lock & tmpfs        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Security Considerations

### Tmpfs vs Regular Disk
- **Tmpfs (`/dev/shm`)** : RAM-backed, aucune persistence après nettoyage
- **Disque** : Persistent, forensic recovery possible
- **Decision** : Utiliser tmpfs pour manipulation intermédiaire

### No-log Protection
```yaml
- name: Sensitive task
  set_fact:
    vault_data: ...
  no_log: true  # Empeche le logging du stdout Ansible
```

### POSIX Lock
- **Problem** : 2 playbooks modifient vault.yml simultanément → corruption
- **Solution** : `flock -x` acquiert lock exclusif sur fichier
- **Timeout** : Pas de timeout (attends indéfiniment) = sûr mais peut bloquer

### Atomic Move
- **Problem** : `mv` interrompu peut laisser fichier partiellement écrit
- **Solution** : `install` command = atomic rename + permissions
- **Garantie** : POSIX atomic operation = jamais d'état intermédiaire

## Testing Strategy

### Unit Tests (vault_mutator_autogen_test.yml)
- Génère scalars (default + generated + override)
- Génère kv_lists
- Verify output dans vault.yml

### Integration Tests (minio.yml, traefik.yml)
- Pre-tasks : load → autogen → mutate
- Main-tasks : déploiement réel
- Post-tasks : mutation dynamique → re-persist

## Future Improvements

- [ ] Support multiple vault IDs (actuellement "default" uniquement)
- [ ] Versioning/historique des secrets
- [ ] Synchro multi-machines (actuellement mono-repo)
- [ ] Integration tests CI/CD
- [ ] Secrets rotation scheduling

---

**Questions ?** Ouvrir une issue GitHub ! 🚀
