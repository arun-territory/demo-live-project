# Top-level Makefile — just helps you find the right folder.
# All real commands live in shared-infra/, project-1-inference/, project-3-rag/.

.PHONY: help
help:
	@echo ""
	@echo "  This repo has 3 self-contained folders. Use them in order:"
	@echo ""
	@echo "  1. shared-infra/         -- Build the empty Kubernetes cluster"
	@echo "     cd shared-infra && make apply"
	@echo ""
	@echo "  2. project-1-inference/  -- Deploy the private LLM (vLLM + gateway)"
	@echo "     cd project-1-inference && make deploy"
	@echo ""
	@echo "  3. project-3-rag/        -- Deploy document Q&A on top of Project 1"
	@echo "     cd project-3-rag && make apply && make deploy"
	@echo ""
	@echo "  Bootstrap (one-time GCP setup):"
	@echo "     bash scripts/bootstrap.sh"
	@echo ""
	@echo "  If you don't know what any of this means, read docs/learn-first.md first."
	@echo ""

.PHONY: bootstrap
bootstrap: ## One-time GCP setup (enable APIs, create tfstate bucket)
	bash scripts/bootstrap.sh
