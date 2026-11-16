# 浮光 · U 盘离线 AI

浮光是一套面向 Windows 的便携式本地 AI：把程序、模型、缓存、聊天和生成图片放在同一块 U 盘或移动硬盘里，插上即可运行。模型下载完成后，聊天、看图和生图均可离线使用。

## 现在能做什么

- **中文聊天与看图**：Gemma 3 4B 多模态模型，支持文字问答和 PNG/JPG/WebP 图片理解。
- **本地生图**：普通轻薄本使用 SD-Turbo；检测到独显后自动启用 Vulkan；安装可选模型且显存达到 10GB 时自动切换 SDXL-Turbo。
- **完整会话管理**：对话按日期保存在 U 盘，可重命名、删除；发错的问题可以直接编辑重发，旧回答会从编辑点之后替换。
- **顺滑的桌面界面**：流式回答、过渡动画、侧栏和弹窗均针对桌面与触控板操作做了优化。
- **自动收尾后台**：关闭浮光窗口、按运行窗口中的 `Q`、关闭运行窗口，或运行停止脚本，都会结束模型与生图进程。
- **本地隐私保护**：服务只监听 `127.0.0.1`，存档接口使用每次安装生成的随机令牌。

## 使用方法

### 完整离线包（推荐）

在 [Releases](https://github.com/doxhj007/floatlight-offline-ai/releases) 下载同一版本的全部 `Floatlight-Full-*.part*.bin` 分卷、`Floatlight-Full-manifest.json`、`安装浮光完整离线包.cmd` 和 `Install-FloatlightFull.ps1`，放在同一个文件夹后双击安装器。完整包包含 Gemma 3 4B、SD-Turbo 和 SDXL-Turbo，安装完成后可断网直接运行，不需要再下载模型。

GitHub 要求单个发布文件小于 2 GiB，因此完整包使用分卷；安装器会流式还原并逐文件校验，不会额外占用一份临时压缩包空间。

### 源码版

1. 下载仓库 ZIP，并把解压后的全部内容放到 U 盘或移动硬盘根目录。
2. 双击 **`首次使用-下载基础模型.cmd`**。基础模型约 5.2GB，支持断点续传并在完成后校验 SHA-256。
3. 双击 **`点击启动-浮光离线AI.cmd`**。程序会自动判断使用独显还是 CPU。

首次冷启动会从 U 盘读取约 4GB 模型，慢速 U 盘可能需要 3–5 分钟；运行窗口会持续显示加载进度。Chrome 启动进程切换到正式窗口时，浮光会继续保持后台服务，避免窗口刚出现就退出。

有 10GB 以上显存时，可以再运行 **`可选-下载SDXL精细生图模型.cmd`**；该模型约 3.94GB。显卡驱动或 Vulkan 不兼容时，运行 **`备用-纯CPU启动.cmd`**。

Windows 10/11 自带的 PowerShell 和 `curl.exe` 即可完成安装，不要求 Python。`PortableAI/tools/download_models.py` 是功能相同的 Python 备用下载器。

## 文件都存在哪里

路径会跟随软件所在盘符，不会写死为 `F:`：

| 内容 | 位置 |
| --- | --- |
| 聊天记录 | `盘符:\AI聊天记录\日期\对话编号\` |
| 生成图片 | `盘符:\AI生成图片\日期\` |
| 模型 | `盘符:\PortableAI\models\` |
| 缓存、日志、浏览器资料 | `盘符:\PortableAI\` 内对应目录 |

启动器会把 `TEMP`、`TMP`、模型缓存和独立浏览器资料指向软件所在盘。模型运行时仍会使用系统内存与显存。

## 硬件自适应

| 检测结果 | 聊天/识图 | 生图配置 |
| --- | --- | --- |
| 无可用独显或强制 CPU | Gemma 3 4B CPU | SD-Turbo，384×384，4 步 |
| 3GB–10GB 独显 | Gemma 3 4B Vulkan | SD-Turbo，512×512，4 步 |
| ≥10GB 独显且装有可选模型 | Gemma 3 4B Vulkan | SDXL-Turbo，512×512，4 步 |

生图服务按需启动，第一次生图需要加载模型；之后复用同一进程，速度会明显提升。停止应用后不会留下生图服务占用显存。

## 实测

2026-11-13 在 Lenovo Y7000P、RTX 4050 Laptop 6GB、16GB 内存上完成整套自测：中文界面、U 盘存档、文字回答、图片理解、GPU 生图和纯 CPU 生图全部通过。

- RTX 4050 / SD-Turbo：首次加载并生成约 **14.2 秒**，同进程第二张约 **2.1 秒**。
- 纯 CPU / SD-Turbo：首次加载并生成约 **44.7 秒**，同进程第二张约 **12.5 秒**。
- Gemma 首次加载受 U 盘速度和 Windows 文件缓存影响较大；测试中热缓存加载约 7–44 秒。

这些是单台机器的实测值，U 盘、CPU、显卡和驱动不同会影响结果。

## 启动问题

- 页面没有自动打开时，保持运行窗口不要关闭，手动访问 `http://127.0.0.1:17860/portable-chat.html`。
- 正常退出可直接关闭浮光窗口；也可以在运行窗口按 `Q`，或双击 `停止浮光AI.cmd`。
- 启动窗口若显示模型加载进度，说明程序仍在工作，不是闪退。

## 开发与验证

```powershell
# 存档接口的保存、编辑字段与删除测试
powershell -NoProfile -ExecutionPolicy Bypass -File .\PortableAI\tools\test_chatstore.ps1

# 完整 GPU 或 CPU 自测（需要先下载模型）
.\点击启动-浮光离线AI.cmd -SelfTest -NoBrowser
.\备用-纯CPU启动.cmd -SelfTest -NoBrowser
```

前端使用原生 HTML/CSS/JavaScript；启动与硬件选择使用 PowerShell；本地存档及按需生图代理使用运行时编译的 C#。推理由 [llama.cpp](https://github.com/ggml-org/llama.cpp) 和 [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) 提供。

## 许可证

浮光自身源码使用 [MIT License](LICENSE)。仓库内第三方运行时及下载的模型使用各自许可证，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。模型权重不会提交到 Git 仓库。
