# 方式1: 一键执行(推荐)
curl -fsSL https://gist.githubusercontent.com/你的用户名/xxxxxxxx/raw/tuning-debian12-cn.sh | bash

# 方式2: 先下载审查再执行(更安全)
curl -fsSL https://gist.githubusercontent.com/你的用户名/xxxxxxxx/raw/tuning-debian12-cn.sh -o /root/tuning.sh
cat /root/tuning.sh        # 查看内容确认
bash /root/tuning.sh       # 执行

# 方式3: 使用wget
wget -qO- https://gist.githubusercontent.com/你的用户名/xxxxxxxx/raw/tuning-debian12-cn.sh | bash
