.DEFAULT_GOAL := help

.PHONY: help check-node setup doctor generate icons test build install-mac install-devices deploy-relay security verify clean

help:
	@echo "Wrist Remote developer commands"
	@echo "  make setup           Install/check tools, create local config, install dependencies"
	@echo "  make doctor          Validate the local development environment"
	@echo "  make icons           Regenerate deterministic app icons"
	@echo "  make test            Run Swift, Xcode, and relay tests"
	@echo "  make build           Build all Apple targets without signing"
	@echo "  make install-mac     Build, locally sign, and install the Mac bridge"
	@echo "  make install-devices Sign and install the iPhone and Apple Watch apps"
	@echo "  make deploy-relay    Deploy the optional private Internet relay"
	@echo "  make security        Run repository secret and privacy checks"
	@echo "  make verify          Run security, tests, and unsigned builds"

check-node:
	@command -v node >/dev/null 2>&1 || { echo "Node.js 24 or newer is required." >&2; exit 1; }
	@node -e 'const major = Number(process.versions.node.split(".")[0]); if (!Number.isInteger(major) || major < 24) { console.error(`Node.js 24 or newer is required; found $${process.versions.node}.`); process.exit(1); }'

setup: check-node
	@scripts/bootstrap.sh

doctor: check-node
	@scripts/doctor.sh

generate:
	@cd apps/WristRemote && xcodegen generate --spec project.yml
	@cd apps/WristRemoteBridge && xcodegen generate --spec project.yml

icons:
	@swift scripts/generate-icons.swift

test: check-node
	@scripts/test-all.sh

build: check-node
	@scripts/build-all.sh

install-mac: check-node
	@scripts/build-macos.sh --install

install-devices:
	@scripts/install-devices.command

deploy-relay: check-node
	@scripts/deploy-relay.sh

security:
	@scripts/security-check.sh

verify: security test build

clean:
	@rm -rf apps/WristRemote/.build apps/WristRemote/build apps/WristRemoteBridge/.build apps/WristRemoteBridge/build
	@rm -rf apps/WristRemote/WristRemote.xcodeproj apps/WristRemoteBridge/WristRemoteBridge.xcodeproj
	@rm -rf apps/WristRemote/Generated apps/WristRemoteBridge/Generated
	@rm -rf apps/WristRemoteRelay/node_modules apps/WristRemoteRelay/.wrangler
	@rm -f apps/WristRemoteRelay/worker-configuration.d.ts
