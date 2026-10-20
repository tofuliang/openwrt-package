# iptvproxy

轻量 C 版 345iptv 播放代理，作为 OpenWrt `iptvproxy` 网络包构建。功能包括播放页解码、FLV/普通媒体流式转发、HLS 播放列表代理和 `/healthz` 健康检查。

## OpenWrt 包

包元数据位于 `Makefile` 的 `Package/iptvproxy` 定义，运行时安装到 `/usr/sbin/iptvproxy`。依赖为 `libcurl4`；线程和 libc 由目标工具链提供。

在 OpenWrt SDK/buildroot 中，将本目录放入 `package/iptvproxy` 后执行：

```sh
make package/iptvproxy/compile V=s
```

## 本地验证

```sh
make self-test
make test
make smoke
```

默认监听 `0.0.0.0:3450`。环境变量：

- `IPTVPROXY_BIND`：监听地址，例如 `127.0.0.1:8080`。
- `IPTVPROXY_PROXY`：可选 HTTP 出口代理。
- `IPTVPROXY_URL`：可选对外访问基址。
- `IPTVPROXY_LOG_LEVEL`：`error`、`warn`、`info`、`debug` 或 `trace`。

入口：

- `GET /healthz` 返回 `ok`。
- `GET /345iptv?s=<URL 编码后的播放页>` 成功后返回 `/stream/<opaque-id>`。
- HLS 播放列表中的 segment、key、map 和子 playlist 通过 `/hls/<opaque-id>` 代理。

输入 URL、重定向主机、媒体 URL、HLS URI、页面/playlist 大小、变量数量和会话容量均受限；媒体正文采用流式转发。
