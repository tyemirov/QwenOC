.PHONY: ci lint test docs

MPRLAB_GOVERNOR_SKILL ?= $(if $(XDG_CONFIG_HOME),$(XDG_CONFIG_HOME),$(HOME)/.config)/opencode/skills/mprlab-governor

ci: lint test docs

lint:
	@for script in *.command scripts/*.sh; do bash -n "$$script" || exit; done
	@for config in configs/*.jsonc configs/*.json; do jq empty "$$config" || exit; done

test:
	uv run --with pytest python -m pytest tests -q

docs:
	uv run --script "$(MPRLAB_GOVERNOR_SKILL)/scripts/ste.py" review --repo "$(CURDIR)" --changed
