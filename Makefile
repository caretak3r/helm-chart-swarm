# chart-test-swarm — workspace driver.
# Wraps engine/scripts/ with absolute paths so callers never guess cwd.
# Always invoke from the repo root.

ROOT          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENGINE        := $(ROOT)/engine
SCRIPTS       := $(ENGINE)/scripts
ASSERTS       := $(ENGINE)/asserts
TESTGRID      := $(ENGINE)/testgrid
REPORTS       := $(ROOT)/reports

# Consumer-chart project root. Defaults to the bundled example so the
# framework dogfoods itself when run with no overrides.
PROJECT       ?= $(ROOT)/examples/sample-product-chart

# Override at the CLI: make swarm SUITE=pr-subset PROJECT=/path/to/chart-repo
SUITE         ?= pr-subset
SCENARIO      ?=
RUN           ?=
NUM_AGENTS    ?= 2
CLUSTER_NAME  ?= chart-test-swarm

REQUIRED_SCRIPTS := verify.sh cluster-up.sh cluster-down.sh

# Canonical source for the published GitHub Pages dashboard.
PUBLISH_REPORTS   := $(ROOT)/examples/sample-product-chart/chart-test/reports
PUBLISH_SCENARIOS := $(ROOT)/examples/sample-product-chart/chart-test/scenarios
PUBLISH_OUT       := $(REPORTS)/dist

.PHONY: help verify up down scenario swarm aggregate \
        dashboard dashboard-open publish-dashboard swarm-status clean

help:
	@echo "chart-test-swarm — top-level Makefile"
	@echo ""
	@echo "  Path resolution"
	@echo "    ROOT     = $(ROOT)"
	@echo "    ENGINE   = $(ENGINE)"
	@echo "    PROJECT  = $(PROJECT)"
	@echo ""
	@echo "  Sanity"
	@echo "    make verify                preflight: kind/k3d, kubectl, helm, yq"
	@echo ""
	@echo "  Single-scenario run"
	@echo "    make scenario SCENARIO=path/to/scenario.yaml"
	@echo ""
	@echo "  Cluster lifecycle"
	@echo "    make up [CLUSTER_NAME=N]   bring up local cluster"
	@echo "    make down                  tear down"
	@echo ""
	@echo "  Swarm (Phase 3 — not wired yet)"
	@echo "    make swarm SUITE=pr-subset PROJECT=path/to/chart-repo [NUM_AGENTS=N]"
	@echo "    make aggregate RUN=<run-id>"
	@echo ""
	@echo "  Dashboard (Phase 4 — not wired yet)"
	@echo "    make dashboard / dashboard-open"
	@echo "    make publish-dashboard     build reports/dist from canonical examples (CI parity)"
	@echo ""
	@echo "  Other"
	@echo "    make swarm-status          list runs + PASS/FAIL counts"
	@echo "    make clean                 cluster down + rm reports + dist"

verify:
	bash $(SCRIPTS)/verify.sh

up:
	CLUSTER_NAME=$(CLUSTER_NAME) bash $(SCRIPTS)/cluster-up.sh

down:
	CLUSTER_NAME=$(CLUSTER_NAME) bash $(SCRIPTS)/cluster-down.sh

scenario:
	@if [ -z "$(SCENARIO)" ]; then \
	  echo "ERROR: pass SCENARIO=path/to/scenario.yaml"; exit 1; \
	fi
	@if [ ! -f "$(SCENARIO)" ]; then \
	  echo "ERROR: $(SCENARIO) does not exist"; exit 1; \
	fi
	bash $(SCRIPTS)/run-scenario.sh $(SCENARIO)

swarm:
	@RUN_ID="run-$$(date +%Y%m%d-%H%M%S)"; \
	bash $(SCRIPTS)/dispatch-swarm.sh "$(PROJECT)" "$(SUITE)" "$(NUM_AGENTS)" "$$RUN_ID"; \
	echo ""; \
	echo "==> NEXT: spawn $(NUM_AGENTS) helm-engineer agent(s)."; \
	echo "==> Each reads its brief at reports/$$RUN_ID/agent-N/brief.md"; \
	echo "==> When all return, run: make aggregate RUN=$$RUN_ID"

aggregate:
	@if [ -z "$(RUN)" ]; then \
	  echo "ERROR: pass RUN=<run-id>, e.g. make aggregate RUN=run-20260520-101500"; \
	  exit 1; \
	fi
	bash $(SCRIPTS)/aggregate.sh $(RUN)

dashboard:
	bash $(SCRIPTS)/build-dashboard.sh

# Build the publishable dashboard (what GitHub Pages uploads) from the canonical
# examples reports/scenarios into top-level reports/dist. Mirrors the CI build.
publish-dashboard:
	REPORTS_DIR=$(PUBLISH_REPORTS) \
	SCENARIOS_DIR=$(PUBLISH_SCENARIOS) \
	DASHBOARD_OUT=$(PUBLISH_OUT) \
	bash $(SCRIPTS)/build-dashboard.sh

dashboard-open:
	@open $(TESTGRID)/dist/index.html 2>/dev/null || xdg-open $(TESTGRID)/dist/index.html 2>/dev/null || \
	  echo "open $(TESTGRID)/dist/index.html manually"

swarm-status:
	@found=0; \
	for d in $(REPORTS)/run-*; do \
	  [ -d "$$d" ] || continue; \
	  found=1; \
	  rid=$$(basename $$d); \
	  csv="$$d/scenario-matrix.csv"; \
	  if [ -f "$$csv" ]; then \
	    pass=$$(awk -F, 'NR>1 && $$3=="PASS"{c++} END{print c+0}' "$$csv"); \
	    fail=$$(awk -F, 'NR>1 && $$3=="FAIL"{c++} END{print c+0}' "$$csv"); \
	    part=$$(awk -F, 'NR>1 && $$3=="PARTIAL"{c++} END{print c+0}' "$$csv"); \
	    printf "  %-30s  PASS=%-3d FAIL=%-3d PARTIAL=%-3d\n" "$$rid" $$pass $$fail $$part; \
	  else \
	    printf "  %-30s  (no scenario-matrix.csv — not aggregated)\n" "$$rid"; \
	  fi; \
	done; \
	[ $$found -eq 1 ] || echo "  (no runs under $(REPORTS)/)"

clean:
	-CLUSTER_NAME=$(CLUSTER_NAME) bash $(SCRIPTS)/cluster-down.sh
	rm -rf $(REPORTS) $(TESTGRID)/dist
