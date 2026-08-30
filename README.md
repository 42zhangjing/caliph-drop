# Caliph Drop 0.3

这是为你的 CALIPH 网站定制的 macOS 菜单栏图片上传器。

日常动作只有一个：

```text
Finder 图片
   ↓ 拖到 Mac 顶部菜单栏的 Caliph Drop 图标
本机压缩（2560px / 0.88 / WebP 优先）
   ↓
POST https://caliph.chengyu.dev/api/drop
   ↓
Worker 验证专用 Token
   ↓
R2 保存图片 + D1 自动新增图库记录
   ↓
网站图库立刻出现
```

0.3 同时支持把 Finder 图片拖进点击菜单栏图标后出现的大型虚线区域。弹窗可通过点击外部区域或按 `Escape` 收起；上传会继续在后台执行，菜单栏图标会显示上传中、成功或失败状态。

## 这个版本为什么需要一个很小的 Worker 补丁

你现在的后台上传并不是“只丢进 R2”。现有流程会：

1. 先创建一条 collection 记录；
2. 浏览器把图片压成 WebP；
3. 再上传到 `/api/admin/media?collectionId=...`；
4. R2 保存文件；
5. D1 的 `collection_media` 记录图片与 collection 的关系。

并且 `/api/admin/*` 必须经过 Cloudflare Access 登录，所以原样给桌面 App 调用并不方便。

因此 Caliph Drop 增加一个专门的：

```text
POST /api/drop
```

它**不会绕开你现有后台**，也不会改变原来的后台上传逻辑；它只为你自己的 Mac 提供一个带独立 Token 的快速入口。

## 第一步：给网站加 `/api/drop`

把本目录的：

```text
runtime-dropUpload.js
```

复制到你的项目：

```text
runtime/dropUpload.js
```

然后修改 `cloudflare/worker.js`：

```js
import { handleDropUploadRequest } from "../runtime/dropUpload.js";
```

并在 `fetch()` 中加入：

```js
if (url.pathname === "/api/drop") {
  return handleDropUploadRequest(request, env);
}
```

或者直接使用本目录的：

```text
caliph-drop-server.patch
```

在项目根目录执行：

```bash
git apply /你的路径/caliph-drop-server.patch
```

## 第二步：设置专用上传 Token

不要把 Token 写进 GitHub / `wrangler.jsonc`。

在项目根目录执行：

```bash
openssl rand -hex 32
```

会得到一串类似：

```text
4db7...（64位随机字符串）
```

复制它，然后执行：

```bash
npx wrangler secret put CALIPH_DROP_TOKEN
```

把刚才那串 Token 粘进去。

这个 Token 以后也填进 Caliph Drop App。App 会存到 macOS Keychain。

## 第三步：部署网站

按你原来的 Cloudflare Worker 部署流程即可，例如：

```bash
npm test
npm run build
npx wrangler deploy
```

如果你的 `package.json` 使用了不同脚本，以项目现有脚本为准。

## 第四步：构建 Mac App

在这个 Caliph Drop 文件夹里双击：

```text
build.command
```

或终端执行：

```bash
bash build.command
```

如果电脑还没有 Apple Command Line Tools：

```bash
xcode-select --install
```

完成后会出现：

```text
Caliph Drop.app
```

打开后顶部菜单栏会出现上传图标。

## 第五步：第一次设置

点击顶部图标 → 设置：

- 上传地址已经默认：`https://caliph.chengyu.dev/api/drop`
- `CALIPH_DROP_TOKEN`：填第二步生成的 Token
- “上传后立即发布到图库”：默认开
- “使用文件名作为标题”：默认关
- “成功后复制最后一张图片 URL”：默认开
- “登录时自动启动”：默认关，可按需要开启
- 最长边：2560px
- 质量：0.88

之后就不用再进后台上传图片。设置中的 Token 会保存在 macOS Keychain；如果保存失败，App 会显示错误并保留设置页，不会静默丢失旧 Token。

## 日常使用

从 Finder 一次选 1 张或 15 张图片，直接拖到屏幕顶部的 Caliph Drop 图标；也可以点击图标后拖进虚线框，或使用“选择图片上传”。

App 会依次：

```text
压缩 → 上传 → R2 → D1 → 图库
```

成功后最后一张图片的公开 URL 默认会复制到剪贴板。

## 本地验证

```bash
./test.command
CALIPH_DROP_NO_OPEN=1 ./build.command
```

生产图库烟测默认被锁住，只有明确允许产生一条公开验证记录时才运行：

```bash
CALIPH_DROP_ALLOW_LIVE_TEST=1 ./live-test.command
```

## 安全设计

- 不把 R2 Access Key 放进 App。
- 不把 Cloudflare API Token 放进 App。
- App 只保存一个权限非常单一的 `CALIPH_DROP_TOKEN`。
- Token 放在 macOS Keychain。
- Worker 使用 HTTPS Bearer Token 校验。
- 如果 Token 泄露，只需要重新设置 `CALIPH_DROP_TOKEN`，不用更换 R2/Cloudflare 管理密钥。

## 与你现有压缩规则一致

现有后台规则是：

- 最长边 2560px；
- WebP；
- quality 0.88；
- 如果转换后反而更大，保留原图。

Caliph Drop 0.3 同样采用 2560 / 0.88，并优先用 macOS 系统 WebP 编码器。若系统不提供 WebP 写入能力，普通照片回退 JPEG，透明图片回退 PNG。只有原图已经满足尺寸要求、没有相机/GPS 等私密元数据且重新编码没有更小时，才保留原文件；否则上传去除这些元数据后的处理版本。

## 注意

这个压缩是在你的 Mac 上发生，所以 R2 收到的通常已经是“瘦身后的图片”。访问网站的人看到/下载的也是 R2 中这份处理后的文件。上传采用文件流，不会一次把整张处理后图片读入内存；服务端现有单文件上限为 50 MB。
