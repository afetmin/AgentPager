"use strict";
const statusLine = document.getElementById("status");
const details = document.getElementById("details");
const button = document.getElementById("check");

async function check() {
  button.disabled = true;
  statusLine.textContent = "正在检查本机连接…";
  details.textContent = "";
  try {
    const result = await chrome.runtime.sendMessage({ type: "agentpagerCheckBridge" });
    if (!result?.ok) {
      statusLine.textContent = "未连接到兼容的 AgentPager";
      details.textContent = result?.httpStatus
        ? `本机返回 HTTP ${result.httpStatus}。请确认已退出旧版网页桥并打开整合版。`
        : "请确认整合版 AgentPager 正在运行，并在「网页监测」页面查看监听状态。";
    } else if (result.enabled === false) {
      statusLine.textContent = "网页监测已在 AgentPager 中关闭";
    } else if (result.tabCount === 0) {
      statusLine.textContent = "已连接，尚未收到 ChatGPT 页面数据";
      details.textContent = "请刷新 ChatGPT 标签页，并确认扩展有权访问该站点。";
    } else {
      statusLine.textContent = `已连接 · ${result.tabCount} 个 ChatGPT 标签页`;
      details.textContent = result.sidebarRows
        ? `最近采样：侧栏 ${result.sidebarRows} 条会话，${result.spinningRows} 条正在转圈。`
        : "页面脚本已运行，但没识别到侧栏会话。请展开 ChatGPT 侧栏。";
    }
  } catch (_) {
    statusLine.textContent = "无法访问扩展后台，请在扩展管理页查看错误。";
  } finally { button.disabled = false; }
}

button.addEventListener("click", check);
void check();
