# Contributing

Merci d'être intéressé par contribuer à `ansible-vault-dynamic-secrets` ! 🎉

## Comment contribuer

### Signaler un bug
- Ouvrir une issue GitHub avec le titre clair
- Fournir étapes de reproduction
- Indiquer votre version Ansible + système d'exploitation
- Attacher les logs/erreurs (masquer les secrets !)

### Proposer une feature
- Ouvrir une issue avec le tag `enhancement`
- Décrire le cas d'usage
- Proposer l'implémentation

### Soumettre un PR
1. Fork le repository
2. Créer une branche feature : `git checkout -b feature/my-feature`
3. Commiter les changements : `git commit -am 'Add my feature'`
4. Push : `git push origin feature/my-feature`
5. Ouvrir une Pull Request

## Standards de code

- **Ansible** : Suivre les bonnes pratiques [Ansible Style Guide](https://docs.ansible.com/ansible/latest/user_guide/style_guide/)
- **YAML** : 2 espaces d'indentation
- **Documentation** : Ajouter des commentaires sur les tâches complexes
- **Security** : Utiliser `no_log` pour les données sensibles
- **Tests** : Tester avec `vault_mutator_autogen_test.yml`

## Code de Conduite

Voir [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

---

**Merci pour ta contribution !** 🚀
