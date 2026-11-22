修复了:
QQ号硬编码进Git、WebUI密钥明文广播、QQ rkey 外泄至第三方服务、插件路由鉴权绕过（P1级）、
GPU渲染崩溃风险、中文编码乱码、cleanupOrphanedProcesses() 自杀式清理、qq-unpack.ps1 的以及其他文件的 D 盘路径

品鉴方法：拷贝你的QQNT，将其放到SnowCat的根目录下<img width="558" height="353" alt="image" src="https://github.com/user-attachments/assets/7c06c49f-6f71-44e5-896d-b988761b2afd" />像这样丢进去。找到路径.\release-tools\build用powershell运行snowcat-run.ps1
 启动前检查（非常重要）
Node 依赖装了吗？
--powershell
npm install express ws
环境变量配了吗？
--powershell
$env:QQ_ACCOUNT="你的测试QQ号"
poweshell管理运行
cd snowcat安装路径\SnowCat\release-tools\build
.\snowcat-run.ps1 -QqUin "你的测试QQ号" -Shell "QQNT的路径，或直接填上边路径.\SnowCat\QQNT"
有问题就把报错丢给deepseek看，记得附带本仓库链接，非常感谢ds的指导，耗时一上午才得以勉强运行。
不提供技术支持，有能力就继续修复它，直到变成可以用的水平，品鉴了一上午的史，以及雷霆般的readme.md檄文
