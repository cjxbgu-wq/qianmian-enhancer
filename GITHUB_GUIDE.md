# GitHub Actions 自动编译使用指南

## 🚀 一键编译方法

### 第一步：创建 GitHub 仓库
1. 注册/登录 GitHub 账号
2. 点击右上角 `+` → `New repository`
3. 仓库名随便取，比如 `qianmian-enhancer`
4. 选择 `Public` 或 `Private` 都可以
5. 不用勾选任何初始化选项，直接创建

### 第二步：上传代码

**方法A：网页直接上传（最简单）**
1. 进入刚创建的仓库
2. 点击 `uploading an existing file`
3. 把 `qianmian-enhancer` 文件夹里的**所有文件**拖进去
4. 底部点击 `Commit changes`

**方法B：用 Git 命令**
```bash
cd qianmian-enhancer
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```

### 第三步：触发编译
1. 进入仓库的 `Actions` 标签页
2. 左边选择 `Build Qianmian Enhancer`
3. 右边点击 `Run workflow` → 绿色按钮确认
4. 等待 2~3 分钟编译完成

### 第四步：下载 deb 文件
1. 编译完成后，点进那个成功的 workflow
2. 页面底部 `Artifacts` 区域
3. 点击 `QianmianEnhancer-deb` 下载
4. 解压后就是 `.deb` 安装包

---

## ⚙️ 工作流说明

配置文件位置：`.github/workflows/build.yml`

**自动触发条件：**
- 推送代码到 main/master 分支时自动编译
- 也可以手动点击 `Run workflow` 触发

**编译环境：**
- macOS 最新版
- Theos 最新版
- iOS 15.5 SDK
- 支持 arm64 + arm64e

---

## ❓ 常见问题

### Q: 编译失败，SDK 下载失败？
A: 换一个 SDK 下载链接。编辑 `.github/workflows/build.yml` 里的 SDK 地址：
- 可以从 https://github.com/xybp888/iOS-SDKs/releases 找其他版本
- 或者用你自己的 SDK 上传到网盘

### Q: 提示 `Theos` 相关错误？
A: 检查 workflow 日志，一般是网络问题，重新运行一次就行。

### Q: 编译出来的 deb 安装后没效果？
A: 
1. 确保已经安装了原版「千面-VCAM」
2. 检查设备架构是否匹配（arm64e）
3. 查看手机的 Crash 日志

---

## 📝 本地修改后重新编译
每次修改代码后：
1. 提交并推送到 GitHub
2. Actions 会自动开始编译
3. 2分钟后下载新的 deb
