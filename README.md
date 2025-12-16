# OpenWrt ech-wk 一键部署脚本

本项目提供一个简单的一键脚本，用于在 **OpenWrt** 上快速部署并运行ech-wk    
修改自byJoey的ech-kw项目中softrouter.sh脚本，解决无限写入日志的问题   

## 🚀 使用方法

在 OpenWrt 设备上执行以下命令：  

```bash
wget https://raw.githubusercontent.com/huanchenshang/ech-wk/refs/heads/main/ech.sh
chmod +x ech.sh
ln -s /root/ech.sh /usr/bin/ech
```
以后运行只需要输入ech即可
