# pinvou3 Windows Runtime

本仓库保存 PINVOU Windows 端的运行时资源，由主仓库
`Pinvou/pinvou3` 通过 submodule commit 精确引用。

## 目录

`payload/` 是本地打包和物化目录，不再提交二进制或新的 LFS 指针。Git 只跟踪 manifest、脚本和文档。

- `payload/7zip-runtime.zip`：7-Zip 运行时；
- `payload/asr-runtime.zip`：ASR wrapper、SenseVoice backend 和 FSMN VAD；识别模型不随安装包分发，由应用按需下载；
- `payload/poppler-runtime.zip`：PDF 工具；
- `payload/tesseract-runtime.zip`：OCR 工具和语言数据；
- `payload/vc_redist`：VC++ Redistributable；
- `payload/*.zip`：Python、Node.js、Pandoc 和 ONNX Runtime 上游组件包；
- `windows-runtime.manifest.json`：仓库资源、组件 ZIP 内容以及最终 staging 文件集合的可信 SHA-256 清单。

二进制内容通过本仓库 `runtime-<完整 commit>` Release 的附件分发。历史 LFS 指针保留在旧提交中，
新提交忽略 `payload/`，不再生成新的 LFS 指针。消费者初始化固定 gitlink，再从该提交对应的
Release 下载附件并校验大小和 SHA256。无需 Git LFS 下载额度，禁止使用 `latest`。
禁止 force-push、覆盖已有历史或替换已发布附件；资源升级通过新 commit 和新 Release 追加。
主仓库更新 submodule gitlink 后才会进入发布构建。

主仓库当前锁定版本的全部原始归档已经校验并发布至
[runtime-dcde8f01dc009c4acecfbe3bc64dff39de22d341](https://github.com/Pinvou/pinvou3-windows-runtime/releases/tag/runtime-dcde8f01dc009c4acecfbe3bc64dff39de22d341)，
版本和内容不变。新 main 可以直接 clone，不触发 LFS 下载。检出旧的 LFS 历史版本前设置
`GIT_LFS_SKIP_SMUDGE=1`；主仓库 `npm run runtime:windows:init` 自动设置它并按固定 Release 物化。

## 更新资源

1. 在仓库外的临时目录中展开并修改对应组件；
2. 使用确定性打包脚本更新组件 ZIP：

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

   ASR 包只允许包含 `models/fsmn-vad.gguf`；`sensevoice-small-*` 等识别模型必须由应用按需下载，manifest 生成脚本会拒绝把它们写入运行时包。

4. 验证 manifest 可重复生成、staging 清单路径唯一且 ASR 未混入识别模型：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-manifest.ps1
   ```

5. 核对 manifest 中所有文件的大小和 SHA256；`payload/` 已忽略，不生成或提交 LFS 指针；
6. 仅提交 manifest、脚本和文档并正常推送；此时尚不可更新主仓库 gitlink。跳过 LFS 上传不能代替迁移，因为 GitHub 会拒绝引用未上传 LFS 对象的新提交；
7. 从仍保存完整 `payload/` 的目录运行 `python scripts/publish-release.py --commit <完整 commit> --payload-root <目录> --check-only`；
8. 去掉 `--check-only` 发布。脚本先验证提交内的 manifest 与所有原始文件，创建 draft、上传附件并核对 GitHub 服务端摘要，最后公开 Release；已存在的标签或 Release 会拒绝覆盖；
9. 发布失败时先检查保留的 draft，保持主仓库旧 gitlink。发布成功后在主仓库更新 gitlink 和 lock manifest；
10. 从干净 checkout 执行 Windows runtime staging 和安装包验证。

发布工具使用 Python 3 和已认证的 GitHub CLI，仅在实际发布时需要写权限；构建下载为匿名 HTTPS。
回滚时先回退消费者的 gitlink/transport 变更，保留旧标签、附件和历史；不得覆盖旧附件来实现回滚。

主仓库的普通 `cargo check` 不依赖本 submodule；只有 Windows 发布构建需要初始化它。
