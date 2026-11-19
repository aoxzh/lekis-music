// 最小本地测试插件：不访问网络，只验证安装 / 启用 / 设置界面。
export function lyrics() {
  const greeting = host.setting("greeting") ?? "你好，Lekis！";
  return { synced: false, text: `${greeting}\n\n这是一个本地测试插件。` };
}
