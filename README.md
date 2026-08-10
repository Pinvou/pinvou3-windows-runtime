# pinvou3 Windows Runtime

本仓库保存 PINVOU Windows 端的私有运行时资源，由主仓库
`Pinvou/pinvou3` 通过 submodule commit 精确引用。

## 目录

- `payload/7zip-runtime.zip`：7-Zip 运行时；
- `payload/asr-runtime.zip`：ASR wrapper、SenseVoice backend 和模型；
- `payload/asr/pinvou-asr.exe`：经过 manifest 锁定的 wrapper overlay，主仓 staging 校验 ZIP 后以此文件覆盖旧入口；
- `payload/poppler-runtime.zip`：PDF 工具；
- `payload/tesseract-runtime.zip`：OCR 工具和语言数据；
- `payload/vc_redist`：VC++ Redistributable；
- `payload/*.zip`：Python、Node.js、Pandoc 和 ONNX Runtime 上游组件包；
- `windows-runtime.manifest.json`：仓库级资源以及四个自维护组件 ZIP 内部文件的 SHA-256 清单。

二进制文件统一使用 Git LFS。禁止 force-push 或覆盖已有历史；资源升级通过新 commit
追加，主仓库更新 submodule gitlink 后才会进入发布构建。

## 更新资源

1. 只更新 ASR wrapper 时，替换 `payload/asr/pinvou-asr.exe`，保留 backend 和模型归档；
2. 更新其他 ASR 文件或组件时，在仓库外的临时目录中展开并修改对应组件，再使用确定性打包脚本更新组件 ZIP：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-component.ps1 `
     -SourceDirectory D:\runtime-work\asr `
     -OutputPath payload\asr-runtime.zip `
     -Force
   ```

3. 重新生成 manifest：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/update-manifest.ps1
   ```

4. 确认 `git lfs status` 中所有二进制均由 LFS 管理；
5. 提交并推送；
6. 在主仓库更新 submodule commit 和 lock manifest；
7. 从干净 checkout 执行 Windows runtime staging 和安装包验证。

主仓库的普通 `cargo check` 不依赖本 submodule；只有 Windows 发布构建需要初始化它。
