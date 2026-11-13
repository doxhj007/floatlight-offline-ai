# 第三方组件与模型

浮光的 MIT 许可证只覆盖本项目自身源码。运行时和模型继续受各自许可证约束。

## 随仓库提供的运行时

- [llama.cpp](https://github.com/ggml-org/llama.cpp)，构建 12283 / commit `f3b407ca1`，MIT。用于 Gemma 文字与图片推理。
- [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)，commit `465adf3`，MIT。用于本地文字生图和持久生图服务。
- LLVM OpenMP runtime。许可证文本随二进制保存在 `PortableAI/runtime-cpu/LICENSE-LLVM-OpenMP` 和 `PortableAI/runtime-gpu/LICENSE-LLVM-OpenMP`。

`PortableAI/runtime-image/ggml.txt` 与 `PortableAI/runtime-image/stable-diffusion.cpp.txt` 保存了对应 MIT 许可证文本。

## 由下载器获取的模型

- [Gemma 3 4B IT GGUF](https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF)：文字和图片理解。使用前请阅读并遵守该模型页面列出的 Gemma 条款。
- [SD-Turbo GGUF](https://huggingface.co/samoudi/sd-turbo-gguf)：基础生图模型，转换自 [stabilityai/sd-turbo](https://huggingface.co/stabilityai/sd-turbo)。使用前请阅读模型页面的 Stability AI 许可证和可接受使用政策。
- [SDXL-Turbo Q4_0 GGUF](https://huggingface.co/gpustack/stable-diffusion-xl-1.0-turbo-GGUF)：可选高显存生图模型。使用前请阅读模型页面列出的 `sai-nc-community` 条款。

下载器会核对固定文件大小和 SHA-256，模型权重不会进入本 Git 仓库。
