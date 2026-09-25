# Makefile — herdr-forward Go 二进制构建/校验入口（PLAN-GO-MIGRATION §4/§6 Phase 0）
#
# 设计取舍：
#   * Go module 根在 go/（模块路径 github.com/zzjcool/herdr-forward，独立于仓库根的
#     package.json），因此所有 go 目标都先 cd go/ 再执行；产物统一落到仓库根 bin/。
#   * 依赖只允许 BurntSushi/toml + golang.org/x/term（PLAN §4 依赖纪律），依赖真身
#     提交在 go/vendor/ 以支持容器离线构建，故默认走 -mod=vendor。
#   * 版本号注入目标与 .goreleaser.yml 的 ldflags 对齐（-X main.version=...），
#     这样 `make build` 的本地二进制与 release 产物打印同一个 version 字段。
#
# 用法：make build | make lint | make test | make vendor-check | make check | make clean

# 配方统一用 bash（错误即停；$$()/管道行为可预期）
SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c

GO_DIR := go
BIN_DIR := bin
BIN := $(BIN_DIR)/forward-go

# 版本：优先取精确 tag，否则退化为短 commit（与 goreleaser 的 {{.Version}} 语义一致）。
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
# 与 .goreleaser.yml 的 ldflags 保持一致（-s -w 之外，本阶段不裁剪符号以便本机调试）。
LDFLAGS := -X main.version=$(VERSION)

# GOFLAGS：优先 vendor 目录（离线可构建），不触碰网络。
export GOFLAGS := -mod=vendor

.PHONY: all build lint fmt vet test vendor-check check clean help

all: check build

## build：产出 bin/forward-go（注入版本号）
build:
	@mkdir -p $(BIN_DIR)
	cd $(GO_DIR) && go build -ldflags '$(LDFLAGS)' -o ../$(BIN) ./cmd/forward
	@echo "built $(BIN) (version=$(VERSION))"

## lint：格式化检查 + go vet（不修改文件）
lint: fmt vet

## fmt：gofmt 格式检查（-d 只报告不写入，与 shfmt -d 的 CI 语义一致）
## 排除 vendor/：第三方代码不归本项目管，其格式变动不应弄红本仓库 CI。
fmt:
	@out="$$(cd $(GO_DIR) && gofmt -l . | grep -v '^vendor/' || true)"; \
	if [ -n "$$out" ]; then \
		echo "gofmt 需要格式化以下文件：" >&2; echo "$$out" >&2; exit 1; \
	fi
	@echo "gofmt clean"

## vet：go vet 静态检查
vet:
	cd $(GO_DIR) && go vet ./...

## test：go 单测
test:
	cd $(GO_DIR) && go test ./...

## vendor-check：哨兵 —— go/vendor 必须与 go.mod/go.sum 一致（PLAN R3）
## 手法：重新生成 vendor 后要求无 diff；同时 go mod verify 校验校验和。
vendor-check:
	cd $(GO_DIR) && go mod verify
	cd $(GO_DIR) && go mod vendor
	@if ! git diff --quiet -- $(GO_DIR)/vendor $(GO_DIR)/go.mod $(GO_DIR)/go.sum; then \
		echo "vendor-check FAIL: go/vendor 与 go.mod/go.sum 不一致（提交重新生成的 vendor）" >&2; \
		git --no-pager diff --stat -- $(GO_DIR)/vendor $(GO_DIR)/go.mod $(GO_DIR)/go.sum >&2; \
		exit 1; \
	fi
	@echo "vendor-check OK（go/vendor 与 go.mod/go.sum 一致）"

## check：本地门 —— lint + test + vendor-check（CI 的 go 段等价集合）
check: lint test vendor-check

## clean：删除构建产物（不碰 vendored 依赖）
clean:
	rm -f $(BIN)
	rm -rf dist

## help：列出目标
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
