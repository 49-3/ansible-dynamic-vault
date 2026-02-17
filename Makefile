# Defaults (adapte si besoin)
VAULT_FILE ?= ansible/group_vars/all/vault.yml
# Utilise un vault-id si tu en as un + fichier de mot de passe
VAULT_ID    ?= default
VAULT_PASS  ?= ansible/.vault-pass
VAULT_ENV   ?= ANSIBLE_VAULT_IDENTITY_LIST='$(VAULT_ID)@$(VAULT_PASS)'

.PHONY: help
help: ## List all makefile targets with their descriptions
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: vault_show
vault_show: ## Affiche le contenu du fichier vault.yml
	@$(VAULT_ENV) ansible-vault view "$(VAULT_FILE)"

.PHONY: vault_encrypt
vault_encrypt: ## Chiffre le fichier vault.yml s'il ne l'est pas déjà
	@if head -n1 "$(VAULT_FILE)" | grep -q '^\$$ANSIBLE_VAULT;'; then \
		echo "✅ Vault déjà chiffré"; \
	else \
		$(VAULT_ENV) ansible-vault encrypt "$(VAULT_FILE)" --encrypt-vault-id "$(VAULT_ID)"; \
		echo "🔐 Vault chiffré avec succès"; \
	fi

.PHONY: vault_decrypt
vault_decrypt: ## Déchiffre le fichier vault.yml s'il est chiffré
	@if grep -qE '^\$$ANSIBLE_VAULT;' "$(VAULT_FILE)"; then \
		$(VAULT_ENV) ansible-vault decrypt "$(VAULT_FILE)"; \
		echo "🔓 Vault déchiffré avec succès"; \
	else \
		echo "⏭️  Le vault est déjà en clair"; \
	fi

.PHONY: commit
commit: vault_encrypt ## Commit les changements avec le message fourni dans la variable m="message de commit"
	@: $${m:?"Usage: make commit m=\"message de commit\""}
	@git add -A
	@if git diff --cached --quiet; then \
		echo "⏭️  Rien à committer"; \
	else \
		git commit -m "$$m"; \
	fi
	@git status -sb
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then git push; else git push -u origin "$$branch"; fi

.PHONY: vault_mutator_autogen_test
vault_mutator_autogen_test: ## Test complet du vault (loader → autogen → mutator)
	@$(VAULT_ENV) ANSIBLE_ROLES_PATH=ansible/roles ansible-playbook ansible/playbooks/vault_mutator_autogen_test.yml

.PHONY: deploy_minio
deploy_minio: ## Déploie MinIO (exemple d'utilisation du vault)
	@$(VAULT_ENV) ansible-playbook ansible/playbooks/minio.yml

.PHONY: deploy_traefik
deploy_traefik: ## Déploie Traefik (exemple d'utilisation du vault)
	@$(VAULT_ENV) ansible-playbook ansible/playbooks/traefik.yml
