# huaweieink.koplugin

华为墨水屏没有公开自己的全刷接口，KOReader 里也没给它做适配，所以 MatePad Paper 上翻页残影清不掉，设置里也找不到全刷间隔。

我们找到了这个接口，并给 KOReader 补上了适配。

现在 KOReader 里就是它原生那套菜单：

```
设置（齿轮） → 屏幕 → E-ink settings → 全刷间隔
    从不 / 每页 / 每 6 页 / 自定义 1·2·3 / 每章
```

## 接口

```java
// /system/framework/eink.framework.jar
android.eink.EPDCDevice.setForceNextPostMode(int mode)   // mode 98 = GC16 全刷
```

不用 root，不改系统，普通 App 就能调。

## 安装

把本仓库整个文件夹放进 KOReader 的插件目录：

```
koreader/plugins/huaweieink.koplugin/
├── main.lua
└── _meta.lua
```

重启 KOReader 即生效。

## 说明

- 只在 **HMW-W09 / HarmonyOS 2.1 / KOReader v2026.07.2** 上验证过
- 依赖 KOReader 内部接口，大版本升级可能失效
- 所有调用都有保护：最坏情况是不生效，不会让 KOReader 崩溃
- 删掉文件夹即恢复原样

## 排错

**没有 E-ink settings 菜单**：设置 → 设备 → 华为墨水屏全刷，确认「原生 E-ink 菜单」是开的。

**设了间隔但不闪**：先点同一菜单里的「立即全刷一次」；再看 KOReader 的 `crash.log`，搜 `[HuaweiEink]`。

## License

MIT
