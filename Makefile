.PHONY: ci lint test

ci: lint test

lint:
	@for script in *.command scripts/*.sh; do bash -n "$$script" || exit; done
	@for config in configs/*.jsonc; do jq empty "$$config" || exit; done

test:
	uv run --with pytest python -m pytest tests -q
