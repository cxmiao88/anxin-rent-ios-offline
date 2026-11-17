# 安心租房 iOS 离线版构建仓库

H5 资源打进 App 包内。壳内部起一个本地 HTTP 服务（`http://127.0.0.1:随机端口`）提供包内 `www/`，页面因此处在正常的 http 源上：ES module、localStorage、同源请求都成立；所有非静态文件的请求由同一服务代转到 `https://cc.scxjydz.com`（后端没有 CORS 头，必须同源代理）。

> 2026-11-18 修正：此前用自定义协议 `anxin://app` 直接读包内文件，iOS 会拒掉带 `crossorigin` 的 `type=module` 脚本（`index.html` 里就是这种写法），导致白屏。已改为本地 HTTP 服务。

- Bundle ID：`com.anxinhuiju.zufang`
- 版本：1.0.8 / 108
- 产物：`AnxinRent.ipa`（未签名），随 Release `v1.0.7-offline` 标签发布（标签名沿用，内容为最新构建）
- 页面资源：构建时从线上 `/h5/` 爬取（与本地构建逐字节一致），写入 `Resources/www/h5`，随包发布
- 开启文件共享（`UIFileSharingEnabled`），App 内 `Documents/shell.log` 记录启动、请求与 JS 报错，可用爱思助手「文件」页导出排查

## 与在线壳的区别

| 项 | 在线壳 | 离线版 |
| --- | --- | --- |
| 页面来源 | 每次启动拉线上 `/h5/` | 包内本地文件 |
| 断网 | 白屏 | 界面仍可打开（接口报错照旧） |
| 服务器改版 | 立刻生效 | 不生效，需重新打包 |
| 接口 | 同源直连 | 经壳内本地服务转发，对页面同源 |
