#!/bin/bash
# ==================================================
# Debian 12 屏蔽/更新/解除 指定国家/地区 IP 段
# 使用 ipset + iptables + cron
# 数据源: http://www.ipdeny.com/ipblocks/
# ==================================================

set -e
ACTION=$1
COUNTRY=$2   # 国家代码（小写，如 cn、ru、us、jp）

BASE_URL="http://www.ipdeny.com/ipblocks/data/countries"
CRON_JOB="0 3 * * * /usr/local/bin/block_country.sh update all >/dev/null 2>&1"

# 确保 root
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 权限运行：sudo bash $0"
  exit 1
fi

install_deps() {
  apt-get update -y
  apt-get install -y ipset iptables wget netfilter-persistent ipset-persistent cron
}

setup_ipset() {
  if ! ipset list | grep -q "$1"; then
    ipset create "$1" hash:net
  fi
}

download_country() {
  local code=$1
  local url="$BASE_URL/${code}.zone"
  echo "📥 下载 ${code} IP 列表..."
  wget -q -O "/tmp/${code}.zone" "$url" || { echo "❌ 下载失败: $url"; exit 1; }
}

apply_rules() {
  local code=$1
  ipset flush "$code"
  while read -r ip; do
    ipset add "$code" "$ip"
  done < "/tmp/${code}.zone"

  if ! iptables -C INPUT -m set --match-set "$code" src -j DROP 2>/dev/null; then
    iptables -I INPUT -m set --match-set "$code" src -j DROP
  fi
  if ! iptables -C OUTPUT -m set --match-set "$code" dst -j DROP 2>/dev/null; then
    iptables -I OUTPUT -m set --match-set "$code" dst -j DROP
  fi

  netfilter-persistent save
}

remove_rules() {
  local code=$1
  iptables -D INPUT -m set --match-set "$code" src -j DROP 2>/dev/null || true
  iptables -D OUTPUT -m set --match-set "$code" dst -j DROP 2>/dev/null || true
  ipset destroy "$code" 2>/dev/null || true
  netfilter-persistent save
}

add_cron() {
  (crontab -l 2>/dev/null | grep -v "/usr/local/bin/block_country.sh update all" || true; echo "$CRON_JOB") | crontab -
}

remove_cron() {
  (crontab -l 2>/dev/null | grep -v "/usr/local/bin/block_country.sh update all" || true) | crontab -
}

status_info() {
  echo "===== 屏蔽状态 ====="
  ipset list 2>/dev/null | grep "Name:" | awk '{print $2}' | while read code; do
    COUNT=$(ipset list "$code" | grep -E "^\d" | wc -l)
    echo "✅ 已屏蔽 [$code]，IP 段数量: $COUNT"
  done

  echo
  echo "===== 定时任务 ====="
  if crontab -l 2>/dev/null | grep -q "/usr/local/bin/block_country.sh update all"; then
    echo "✅ 已启用，每天凌晨 3 点自动更新"
  else
    echo "❌ 未设置自动更新"
  fi
  echo "==================="
}

run_action() {
  case "$1" in
    install)
      if [ -z "$2" ]; then echo "用法: $0 install [国家代码]"; exit 1; fi
      install_deps
      setup_ipset "$2"
      download_country "$2"
      apply_rules "$2"
      add_cron
      echo "✅ 已屏蔽 [$2]，并设置每天凌晨 3 点自动更新"
      ;;
    update)
      if [ "$2" = "all" ]; then
        for code in $(ipset list 2>/dev/null | grep "Name:" | awk '{print $2}'); do
          download_country "$code"
          apply_rules "$code"
        done
        echo "✅ 所有已屏蔽国家更新完成"
      else
        if [ -z "$2" ]; then echo "用法: $0 update [国家代码|all]"; exit 1; fi
        setup_ipset "$2"
        download_country "$2"
        apply_rules "$2"
        echo "✅ 更新完成 [$2]"
      fi
      ;;
    uninstall)
      if [ -z "$2" ]; then echo "用法: $0 uninstall [国家代码|all]"; exit 1; fi
      if [ "$2" = "all" ]; then
        for code in $(ipset list 2>/dev/null | grep "Name:" | awk '{print $2}'); do
          remove_rules "$code"
        done
        remove_cron
        echo "✅ 已解除所有国家屏蔽，定时任务已删除"
      else
        remove_rules "$2"
        echo "✅ 已解除 [$2] 屏蔽"
      fi
      ;;
    status)
      status_info
      ;;
    *)
      echo "用法: $0 {install|update|uninstall|status} [国家代码|all]"
      echo "例如:"
      echo "  $0 install cn      # 屏蔽中国大陆"
      echo "  $0 install ru      # 屏蔽俄罗斯"
      echo "  $0 update cn       # 更新中国大陆 IP"
      echo "  $0 update all      # 更新所有已屏蔽的国家"
      echo "  $0 uninstall cn    # 解除屏蔽中国大陆"
      echo "  $0 uninstall all   # 解除所有屏蔽"
      echo "  $0 status          # 查看状态"
      exit 1
      ;;
  esac
}

# 如果没带参数，进入交互菜单
if [ -z "$ACTION" ]; then
  while true; do
    echo "==============================="
    echo "   国家/地区 IP 屏蔽管理工具"
    echo "==============================="
    echo "1) 安装并屏蔽指定国家"
    echo "2) 手动更新指定国家"
    echo "3) 卸载指定国家"
    echo "4) 更新所有已屏蔽国家"
    echo "5) 卸载所有屏蔽"
    echo "6) 查看当前状态"
    echo "7) 退出"
    echo "==============================="
    read -p "请输入选项 [1-7]: " CHOICE
    case "$CHOICE" in
      1) read -p "请输入国家代码 (如 cn, ru, us): " code; run_action install "$code" ;;
      2) read -p "请输入国家代码 (如 cn, ru, us): " code; run_action update "$code" ;;
      3) read -p "请输入国家代码 (如 cn, ru, us): " code; run_action uninstall "$code" ;;
      4) run_action update all ;;
      5) run_action uninstall all ;;
      6) run_action status ;;
      7) exit 0 ;;
      *) echo "无效选项，请重试" ;;
    esac
    echo
  done
else
  run_action "$ACTION" "$COUNTRY"
fi
