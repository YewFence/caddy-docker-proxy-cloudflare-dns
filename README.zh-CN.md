# Caddy-Docker-Proxy-Cloudflare-DNS
[![CI Pipeline](https://github.com/YewFence/caddy-docker-proxy-cloudflare-dns/actions/workflows/ci-pipeline.yaml/badge.svg)](https://github.com/YewFence/caddy-docker-proxy-cloudflare-dns/actions/workflows/ci-pipeline.yaml)

Endlish Version : [README](README.md)

## 介绍
这个插件让 Caddy 能通过 Docker labels 给容器提供反向代理。
这个分支内置了 Cloudflare DNS 插件（`github.com/caddy-dns/cloudflare`），所以你可以直接使用 DNS-01 验证，不需要自己构建镜像。

## 上游同步
这个仓库有 GitHub Actions 工作流，会从上游 `lucaslorentz/caddy-docker-proxy` 同步变更。
如果能快进合并，就会直接更新 `master`；否则会开一个 PR 提示需要手动解决冲突。
随后会自动尝试把更新合并进 `fork-main`。

> 说明：以下内容来自上游仓库的 README。
---

## 工作原理
插件会扫描 Docker 的元数据，查找表示服务/容器需要被 Caddy 代理的 labels。

它会生成内存里的 Caddyfile：包含各站点条目，以及指向每个 Docker 服务的反向代理（通过服务 DNS 名称或容器 IP）。

每当 Docker 对象发生变化，插件都会更新 Caddyfile，并触发 Caddy 优雅重载，实现零停机。

## 目录

- [Caddy-Docker-Proxy-Cloudflare-DNS](#caddy-docker-proxy-cloudflare-dns)
  - [介绍](#介绍)
  - [上游同步](#上游同步)
  - [工作原理](#工作原理)
  - [目录](#目录)
  - [基础用法示例（Docker Compose）](#基础用法示例docker-compose)
  - [Labels 到 Caddyfile 的转换](#labels-到-caddyfile-的转换)
    - [标记与参数](#标记与参数)
    - [排序与隔离](#排序与隔离)
    - [站点、片段与全局选项](#站点片段与全局选项)
    - [Go 模板](#go-模板)
  - [模板函数](#模板函数)
    - [upstreams](#upstreams)
  - [示例](#示例)
  - [Docker configs](#docker-configs)
  - [代理服务 vs 容器](#代理服务-vs-容器)
    - [服务](#服务)
    - [容器](#容器)
  - [运行模式](#运行模式)
    - [Server](#server)
    - [Controller](#controller)
    - [Standalone（默认）](#standalone默认)
  - [Caddy CLI](#caddy-cli)
  - [Docker 镜像](#docker-镜像)
    - [版本号选择](#版本号选择)
    - [默认与 alpine 镜像的选择](#默认与-alpine-镜像的选择)
    - [CI 镜像](#ci-镜像)
    - [ARM 架构镜像](#arm-架构镜像)
    - [Windows 镜像](#windows-镜像)
    - [自定义镜像](#自定义镜像)
  - [连接 Docker Host](#连接-docker-host)
  - [Volumes](#volumes)
  - [快速试用](#快速试用)
    - [使用 Docker Compose（compose.yaml）](#使用-docker-composecomposeyaml)
    - [使用 run 命令](#使用-run-命令)
  - [构建](#构建)

## 基础用法示例（Docker Compose）
```shell
$ docker network create caddy-net --ipv6
```

> [!NOTE]
> `--ipv6` 参数会让 Docker 为该网络里的所有容器分配 IPv6 地址。
> 没有这个参数时，Caddy（以及上游服务）对 IPv6 客户端会看到 Docker 网关的 IP，而不是实际的客户端 IP。

`caddy/compose.yaml`
```yml
services:
  caddy:
    image: ghcr.io/YewFence/caddy-docker-proxy-cloudflare-dns:ci-alpine
    ports:
      - 80:80
      - 443:443/tcp
      - 443:443/udp
    environment:
      - CADDY_INGRESS_NETWORKS=caddy-net
    labels:
      # ACME 账户邮箱，用于过期与事故通知
      caddy.email: "you@example.com"
      # 通过环境变量里的 token 启用 Cloudflare DNS-01
      caddy.acme_dns: cloudflare {env.CF_API_TOKEN}
      # 使用 cloudflare 做 DNS 解析
      caddy.acme_dns.resolvers: 1.1.1.1
    networks:
      - caddy-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - caddy_data:/data
    restart: unless-stopped

networks:
  caddy-net:
    external: true

volumes:
  caddy_data: {}
```
`caddy/.env`
```
# 确保你的 API Token 有权限修改 DNS 记录
CF_API_TOKEN=your-api-token
```

```shell
$ docker compose up -d
```

`whoami/compose.yaml`
```yml
services:
  whoami:
    image: traefik/whoami
    networks:
      - caddy-net
    labels:
      caddy: whoami.example.com
      caddy.reverse_proxy: "{{upstreams 80}}"

networks:
  caddy-net:
    external: true
```
```shell
$ docker compose up -d
```
现在访问 `https://whoami.example.com`。站点会 [自动启用 HTTPS](https://caddyserver.com/docs/automatic-https)，证书由 Let's Encrypt 或 ZeroSSL 颁发。
		
## Labels 到 Caddyfile 的转换
请先阅读 [Caddyfile 概念](https://caddyserver.com/docs/caddyfile/concepts) 文档，理解 Caddyfile 的结构。

所有前缀为 `caddy` 的 label 都会被转换为 Caddyfile 配置，规则如下：

### 标记与参数

键是指令名，值是用空格分隔的参数：
```
caddy.directive: arg1 arg2
↓
{
	directive arg1 arg2
}
```

如果某个参数里需要空格或换行，用双引号或反引号包裹：
```
caddy.respond: / "Hello World" 200
↓
{
	respond / "Hello World" 200
}
```
```
caddy.respond: / `Hello\nWorld` 200
↓
{
	respond / `Hello
World` 200
}
```
```
caddy.respond: |
	/ `Hello
	World` 200
↓
{
	respond / `Hello
World` 200
}
```

点号表示嵌套，并且会自动分组：
```
caddy.directive: argA  
caddy.directive.subdirA: valueA  
caddy.directive.subdirB: valueB1 valueB2
↓
{
	directive argA {  
		subdirA valueA  
		subdirB valueB1 valueB2  
	}
}
```

父级指令的参数是可选的（例如不给 `directive` 参数，直接设置子指令 `subdirA`）：
```
caddy.directive.subdirA: valueA
↓
{
	directive {
		subdirA valueA
	}
}
```

空值 label 会生成没有参数的指令：
```
caddy.directive:
↓
{
	directive
}
```

### 排序与隔离

注意：指令在解析时会根据 Caddy 的默认 [指令顺序](https://caddyserver.com/docs/caddyfile/directives#directive-order) 进行排序（先从 labels 生成 Caddyfile，再解析）。

来自 labels 的指令默认按字母顺序排序：
```
caddy.bbb: value
caddy.aaa: value
↓
{
	aaa value 
	bbb value
}
```

后缀 _<number> 可以隔离本应自动分组的指令：
```
caddy.route_0.a: value
caddy.route_1.b: value
↓
{
	route {
		a value
	}
	route {
		b value
	}
}
```

前缀 <number>_ 也能隔离指令，同时定义自定义顺序（主要用于 [`route`](https://caddyserver.com/docs/caddyfile/directives/route) 块内），没有前缀的指令会排在最后：
```
caddy.1_bbb: value
caddy.2_aaa: value
caddy.3_aaa: value
↓
{
	bbb value
	aaa value
	aaa value
}
```

### 站点、片段与全局选项

`caddy` 标签会创建一个 [站点块](https://caddyserver.com/docs/caddyfile/concepts)：
```
caddy: example.com
caddy.respond: "Hello World" 200
↓
example.com {
	respond "Hello World" 200
}
```

或者创建一个 [片段](https://caddyserver.com/docs/caddyfile/concepts#snippets)：
```
caddy: (encode)
caddy.encode: zstd gzip
↓
(encode) {
	encode zstd gzip
}
```

也可以使用后缀 _<number> 来隔离多份 Caddy 配置：
```
caddy_0: (snippet)
caddy_0.tls: internal
caddy_1: site-a.com
caddy_1.import: snippet
caddy_2: site-b.com
caddy_2.import: snippet
↓
(snippet) {
	tls internal
}
site_a {
	import snippet
}
site_b {
	import snippet
}
```

[全局选项](https://caddyserver.com/docs/caddyfile/options) 可通过不给 `caddy` 设置值来定义。它们可以在任意容器/服务里定义，包括 caddy-docker-proxy 自身。[示例在这里](examples/standalone.yaml#L19)
```
caddy.email: you@example.com
↓
{
	email you@example.com
}
```

可以在 label 中使用 `@` 创建 [命名 matcher](https://caddyserver.com/docs/caddyfile/matchers#named-matchers)：
```
caddy: localhost
caddy.@match.path: /sourcepath /sourcepath/*
caddy.reverse_proxy: @match localhost:6001
↓
localhost {
	@match {
		path /sourcepath /sourcepath/*
	}
	reverse_proxy @match localhost:6001
}
```

### Go 模板

可以在 label 值里使用 [Golang 模板](https://golang.org/pkg/text/template/) 来提高灵活性。模板里可以访问当前 Docker 资源信息，但要注意：描述容器与描述服务的数据结构不同。

访问服务名可以这样写：
```
caddy.respond: /info "{{.Spec.Name}}"
↓
respond /info "myservice"
```

访问容器名等价写法是：
```
caddy.respond: /info "{{index .Names 0}}"
↓
respond /info "mycontainer"
```

有些 UI 不允许 label 为空值，这时可以用 go 模板生成空值：
```
caddy.directive: {{""}}
↓
directive
```

## 模板函数

以下函数可在模板中使用：

### upstreams

返回当前 Docker 资源的所有地址，使用空格分隔。

对于服务：当 **proxy-service-tasks** 为 **false** 时返回服务 DNS 名称；当 **proxy-service-tasks** 为 **true** 时返回所有运行中的 task IP。

对于容器：返回容器 IP。

只有连接到 Caddy ingress 网络的容器/服务才会被使用。

:warning: caddy docker proxy 会尽力自动检测 ingress 网络，但某些场景会失败：[ #207 ](https://github.com/lucaslorentz/caddy-docker-proxy/issues/207)。更稳妥的方式是手动配置 ingress 网络：使用 CLI 参数 `ingress-networks`、环境变量 `CADDY_INGRESS_NETWORKS`，或为容器/服务加上 `caddy_ingress_network` label 指定网络名称。

用法：`upstreams [http|https] [port]`  

示例：
```
caddy.reverse_proxy: {{upstreams}}
↓
reverse_proxy 192.168.0.1 192.168.0.2
```
```
caddy.reverse_proxy: {{upstreams https}}
↓
reverse_proxy https://192.168.0.1 https://192.168.0.2
```
```
caddy.reverse_proxy: {{upstreams 8080}}
↓
reverse_proxy 192.168.0.1:8080 192.168.0.2:8080
```
```
caddy.reverse_proxy: {{upstreams http 8080}}
↓
reverse_proxy http://192.168.0.1:8080 http://192.168.0.2:8080
```

:warning: 注意 upstreams 的引号，只在 yaml 场景下使用引号。
```
caddy.reverse_proxy: "{{upstreams}}"
↓
reverse_proxy "192.168.0.1 192.168.0.2"
```

## 示例
将所有请求代理到域名对应的容器
```yml
caddy: example.com
caddy.reverse_proxy: {{upstreams}}
```

将所有请求代理到容器内的子路径
```yml
caddy: example.com
caddy.rewrite: * /target{path}
caddy.reverse_proxy: {{upstreams}}
```

只代理匹配路径的请求
```yml
caddy: example.com
caddy.handle: /source/*
caddy.handle.0_reverse_proxy: {{upstreams}}
```

匹配路径并去掉前缀后再代理
```yml
caddy: example.com
caddy.handle_path: /source/*
caddy.handle_path.0_reverse_proxy: {{upstreams}}
```

匹配路径并重写到其他路径前缀
```yml
caddy: example.com
caddy.handle_path: /source/*
caddy.handle_path.0_rewrite: * /target{uri}
caddy.handle_path.1_reverse_proxy: {{upstreams}}
```

代理所有 websocket 请求，以及所有 `/api*` 请求
```yml
caddy: example.com
caddy.@ws.0_header: Connection *Upgrade*
caddy.@ws.1_header: Upgrade websocket
caddy.0_reverse_proxy: @ws {{upstreams}}
caddy.1_reverse_proxy: /api* {{upstreams}}
```

代理多个域名，并为每个域名签发证书
```yml
caddy: example.com, example.org, www.example.com, www.example.org
caddy.reverse_proxy: {{upstreams}}
```

重定向
```yml
caddy: example.com
caddy.redir_0: /favicon.ico  /alternative/icon.ico 302
caddy.redir_1: /photo.png    /updated-photo.png    302
```

**更多社区维护的示例请看 [Wiki](https://github.com/lucaslorentz/caddy-docker-proxy/wiki)。**

## Docker configs

> 注意：仅适用于 Docker Swarm。或者使用 `CADDY_DOCKER_CADDYFILE_PATH` 或 `-caddyfile-path`

你可以通过 Docker configs 把原始 Caddyfile 文本插入到生成的 Caddyfile 开头（不在任何 server block 内）。只要给 config 加上 Caddy label 前缀即可。

[这里有一个示例](examples/standalone.yaml#L4)

## 代理服务 vs 容器
Caddy docker proxy 可以代理 swarm 服务或普通容器。这两种能力始终开启，实际代理哪个取决于你把 labels 写在什么地方。

### 服务
代理 swarm 服务时，labels 必须写在 service 级别。对于 `compose.yaml`，应该放在 `deploy` 里：
```yml
services:
  foo:
    deploy: # <-- labels 要放在 deploy 里
      labels:
        caddy: service.example.com
        caddy.reverse_proxy: {{upstreams}}
```

Caddy 会使用服务 DNS 名称作为目标，或根据 **proxy-service-tasks** 的配置使用所有 task IP。

### 容器
代理容器时，labels 必须写在容器级别。对于 `compose.yaml`，应该写在 `deploy` 之外：
```yml
services:
  foo:
    labels:
      caddy: service.example.com
      caddy.reverse_proxy: {{upstreams}}
```

## 运行模式

每个 caddy docker proxy 实例可运行在以下模式之一。

### Server

作为 Docker 资源的反向代理。Server 启动时没有配置，必须由 “Controller” 配置后才会生效。

要让 Controller 能发现并配置 Server，需要给 Server 添加 `caddy_controlled_server` label，并通过 CLI 参数 `controller-network` 或环境变量 `CADDY_CONTROLLER_NETWORK` 指定 controller 网络。

Server 不需要访问 Docker host socket，可运行在 manager 或 worker 节点。

[配置示例](examples/distributed.yaml#L5)

### Controller

Controller 监控 Docker 集群，生成 Caddy 配置，并推送给集群中发现的所有 Server。

当 Controller 连接多个网络时，也需要通过 CLI 参数 `controller-network` 或环境变量 `CADDY_CONTROLLER_NETWORK` 指定 controller 网络。

Controller 需要访问 Docker host socket。

一个 Controller 就能配置整个集群的所有 Server。

**:warning: Controller 模式要求 Server 节点负责对外服务。**

[配置示例](examples/distributed.yaml#L21)

### Standalone（默认）

在同一实例里同时运行 Controller 和 Server，不需要额外配置。

[配置示例](examples/standalone.yaml#L11)

## Caddy CLI

这个插件为 caddy CLI 扩展了 `caddy docker-proxy` 命令。

运行 `caddy help docker-proxy` 查看所有参数：

```
Usage of docker-proxy:
  --caddyfile-path string
        Path to a base Caddyfile that will be extended with Docker sites
  --envfile
        Path to an environment file with environment variables in the KEY=VALUE format to load into the Caddy process
  --controller-network string
        Network allowed to configure Caddy server in CIDR notation. Ex: 10.200.200.0/24
  --ingress-networks string
        Comma separated name of ingress networks connecting Caddy servers to containers.
        When not defined, networks attached to controller container are considered ingress networks
  --docker-sockets
        Comma separated docker sockets
        When not defined, DOCKER_HOST (or default docker socket if DOCKER_HOST not defined)
  --docker-certs-path
        Comma separated cert path, you could use empty value when no cert path for the concern index docker socket like cert_path0,,cert_path2
  --docker-apis-version
        Comma separated apis version, you could use empty value when no api version for the concern index docker socket like cert_path0,,cert_path2
  --label-prefix string
        Prefix for Docker labels (default "caddy")
  --mode
        Which mode this instance should run: standalone | controller | server
  --polling-interval duration
        Interval Caddy should manually check Docker for a new Caddyfile (default 30s)
  --event-throttle-interval duration
        Interval to throttle caddyfile updates triggered by docker events (default 100ms)
  --process-caddyfile
        Process Caddyfile before loading it, removing invalid servers (default true)
  --proxy-service-tasks
        Proxy to service tasks instead of service load balancer (default true)
  --scan-stopped-containers
        Scan stopped containers and use their labels for Caddyfile generation (default false)
```

这些参数也可以用环境变量设置：

```
CADDY_DOCKER_CADDYFILE_PATH=<string>
CADDY_DOCKER_ENVFILE=<string>
CADDY_CONTROLLER_NETWORK=<string>
CADDY_INGRESS_NETWORKS=<string>
CADDY_DOCKER_SOCKETS=<string>
CADDY_DOCKER_CERTS_PATH=<string>
CADDY_DOCKER_APIS_VERSION=<string>
CADDY_DOCKER_LABEL_PREFIX=<string>
CADDY_DOCKER_MODE=<string>
CADDY_DOCKER_POLLING_INTERVAL=<duration>
CADDY_DOCKER_PROCESS_CADDYFILE=<bool>
CADDY_DOCKER_PROXY_SERVICE_TASKS=<bool>
CADDY_DOCKER_SCAN_STOPPED_CONTAINERS=<bool>
CADDY_DOCKER_NO_SCOPE=<bool, default scope used>
```

请查看 **examples** 目录，了解在 Docker Compose 里如何设置这些参数。

## Docker 镜像
本分支的镜像发布在 GitHub Container Registry：
https://ghcr.io/YewFence/caddy-docker-proxy-cloudflare-dns

### 版本号选择
最稳妥的方式是使用完整版本号，比如 0.1.3。
这样你就锁定在一个已验证的构建版本上。

也可以使用部分版本号，比如 0.1。这意味着你会收到最新的 0.1.x 镜像更新，且不会破坏兼容性。

### 默认与 alpine 镜像的选择
默认镜像非常小且安全，因为只包含 Caddy 可执行文件。
但它们也更难排查问题，因为没有 shell 或 curl、dig 等工具。

`-alpine` 变体基于 Alpine Linux，体积小但带有 shell 与基础工具。适合在更易排障与镜像体积之间做取舍。

### CI 镜像
带 `ci` 标签的镜像来自自动构建，反映 `fork-main` 分支的最新状态，稳定性不保证。
如果你愿意测试最新功能，可以使用 CI 镜像。

### ARM 架构镜像
默认提供 linux x86_64 镜像。

也提供一些其他架构，比如适用于 Raspberry Pi 的 `arm32v6` 镜像。

### Windows 镜像
我们新增了实验性的 Windows 容器镜像，标签后缀为 `nanoserver-ltsc2022`。

这个特性还需要更多测试。

下面是通过 CLI 挂载 Windows Docker pipe 的示例：
```shell
$ docker run --rm -it -v //./pipe/docker_engine://./pipe/docker_engine ghcr.io/YewFence/caddy-docker-proxy-cloudflare-dns:ci-nanoserver-ltsc2022
```

### 自定义镜像
如果你需要额外的 Caddy 插件，或特定版本的 Caddy，可以使用 [官方 Caddy Docker 镜像](https://hub.docker.com/_/caddy) 的 `builder` 变体来自定义 `Dockerfile`。

与官方镜像的主要差异是：你必须覆盖 `CMD`，让容器运行 `caddy docker-proxy` 命令。

```Dockerfile
ARG CADDY_VERSION=2.6.1
FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2 \
    --with <additional-plugins>

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

CMD ["caddy", "docker-proxy"]
```

## 连接 Docker Host
默认连接方式因平台而异：
* Unix：`unix:///var/run/docker.sock`
* Windows：`npipe:////./pipe/docker_engine`

你可以通过以下环境变量修改 Docker 连接方式：

* **DOCKER_HOST**：设置 Docker server 的 URL
* **DOCKER_API_VERSION**：设置 API 版本，留空表示使用最新
* **DOCKER_CERT_PATH**：加载 TLS 证书路径
* **DOCKER_TLS_VERIFY**：启用/禁用 TLS 校验，默认关闭

## Volumes
在生产环境的 Docker Swarm 集群里，**一定要**将 Caddy 的 `/data` 目录挂载到持久化存储。
否则每次重启都会重新签发证书，可能触发 Let's Encrypt 的速率限制。

更稳妥的方式是使用多个 Caddy 副本，并把 `/data` 挂载到支持多重挂载的共享卷（例如网络文件共享插件）。

多个 Caddy 实例在共享 `/data` 时，会自动协调证书签发。

## 快速试用

### 使用 Docker Compose（compose.yaml）

克隆本仓库。

部署 compose 文件到 swarm 集群：
```
$ docker stack deploy -c examples/standalone.yaml caddy-docker-demo
```

等待服务启动...

你可以用不同的 URL 访问不同服务/容器：
```
$ curl -k --resolve whoami0.example.com:443:127.0.0.1 https://whoami0.example.com
$ curl -k --resolve whoami1.example.com:443:127.0.0.1 https://whoami1.example.com
$ curl -k --resolve whoami2.example.com:443:127.0.0.1 https://whoami2.example.com
$ curl -k --resolve whoami3.example.com:443:127.0.0.1 https://whoami3.example.com
$ curl -k --resolve config.example.com:443:127.0.0.1 https://config.example.com
$ curl -k --resolve echo0.example.com:443:127.0.0.1 https://echo0.example.com/sourcepath/something
```

测试完成后，删除 demo stack：
```
$ docker stack rm caddy-docker-demo
```

### 使用 run 命令

```
$ docker run --name caddy -d -p 443:443 -v /var/run/docker.sock:/var/run/docker.sock ghcr.io/YewFence/caddy-docker-proxy-cloudflare-dns:ci-alpine

$ docker run --name whoami0 -d -l caddy=whoami0.example.com -l "caddy.reverse_proxy={{upstreams 80}}" -l caddy.tls=internal traefik/whoami

$ docker run --name whoami1 -d -l caddy=whoami1.example.com -l "caddy.reverse_proxy={{upstreams 80}}" -l caddy.tls=internal traefik/whoami

$ curl -k --resolve whoami0.example.com:443:127.0.0.1 https://whoami0.example.com
$ curl -k --resolve whoami1.example.com:443:127.0.0.1 https://whoami1.example.com

$ docker rm -f caddy whoami0 whoami1
```

## 构建

你可以用 [xcaddy](https://github.com/caddyserver/xcaddy) 或 [caddy docker builder](https://hub.docker.com/_/caddy) 来构建 Caddy。

用模块名 **github.com/lucaslorentz/caddy-docker-proxy/v2** 把这个插件加入构建。
