# 安全说明

浮光的模型服务和存档服务只绑定本机回环地址 `127.0.0.1`。存档接口同时校验随机 Bearer 令牌和页面 Origin；令牌保存在当前盘的 `PortableAI/storage-secret.txt`，该文件已被 Git 忽略。

公开问题中请勿上传 `storage-secret.txt`、`web/storage-config.js`、聊天记录、生成图片或含私人路径的完整日志。若发现可复现的安全问题，请在 GitHub 中创建不包含私人数据的最小复现说明。
