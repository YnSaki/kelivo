# ADR-0054: Input Bar Layout Bucket Keys (输入栏布局桶)

Status: accepted

输入栏按钮自定义（排序 + More 桶）原先存于单一平台无关键 `chat_input_buttons_v1` /
`chat_input_more_buttons_v1`（SQLite KV，经 BusinessPreferences），随备份与 LAN 同步跨设备传输。但「排序 + 收纳桶」是形态耦合的 UI 布局：手机默认 5 直显 + 其余进 More 桶，平板/桌面全直显。跨形态传输 = 互为覆盖——手机（10 项 More 桶）经 LAN 同步写进共享键后，桌面端解析出手机桶，直接按钮变少（issue #570 排查发现的关联缺陷）。本 ADR 将存储按形态（form factor）分桶，消除跨形态覆盖，同时保留同形态设备间的同步/备份。

## Decision

- **两个存储桶，桶选择 = 运行时 `tabletLayout`**（宽度 ≥ `AppBreakpoints.tablet` = 900，与 `resolveInputBarButtonLayout` 既有判定同源）：
  - 平板/桌面布局桶：**legacy 键** `chat_input_buttons_v1` / `chat_input_more_buttons_v1`——零迁移，桌面/iPad 既有定制原样保留。
  - 手机布局桶：新键 `chat_input_buttons_phone_v1` / `chat_input_more_buttons_phone_v1`。
- **旧备份/旧 LAN 对端兼容**：只带 legacy 键 → 新构建恢复端归为平板/桌面桶，无损；phone 桶缺席 = sentinel unset（未自定义），各平台保持 legacy 分割。
- **同形态同步保留**：手机↔手机、桌面↔桌面仍走 LAN 同步/备份（LWW）；跨形态永不传输——这正是修复目标。
- **污染恢复**：已被手机桶覆盖的桌面，用自定义页既有「重置」按钮一次性恢复平板默认布局（不改代码、不加提示，文档化边界）。
- **写出路径**：手机布局的自定义（移动页/桌面对话框按当前宽度选桶后）写入 phone 桶；`SettingsProvider.copy` 克隆助手携带两个桶的字段。

## Compatibility (兼容性)

- **桌面/平板零损失**: tablet/桌面读取路径没有任何变化（legacy 键原样是它们的桶）；唯一例外是已被手机桶覆盖过的桌面——一键「重置」恢复平板默认布局（一次性手动恢复，见前文）。
- **手机侧一次性损失（升级回退）**: 升级前手机用户自定义的布局存于 legacy 键；升级后手机不再读取该键（读 phone 桶），布局静默回退为默认「5 直显 + 其余入桶」。**无迁移路径**——legacy 桶内容的形态归属不可知（可能是桌面的布局），把它迁移进 phone 桶会重新引入本 ADR 要消除的跨形态覆盖（见 Considered）。用户重新自定义一次即可；旧值不删除，继续作为 tablet 桶数据存在于 prefs/备份/Sync 中。
- **旧备份还原**: 携带 legacy 键的旧备份在新构建上归为平板/桌面桶（恢复端设备形态决定谁使用它）：平板/桌面还原无损；手机端还原后为 phone 桶 sentinel 默认态——即手机用户还原了「自己旧的手机布局」时,该布局不会被采用,属同一性一次性损失。

## Considered (rejected)

- **只拆 More 桶（共享排序 + 每形态 More 键）**：排序保守通用，但「More」仍按形态分叉，密钥家族变成 3 个，且排序本身也在手机/桌面间互相覆盖其优先级；分桶模型更简单、每条路径单桶。
- **localOnly（设备本地，不参与备份/同步）**：纯 UI 布局是用户习惯，但桌面↔桌面、手机↔手机的跨设备同步价值真实存在；且与「输入栏是 UI chrome、非设备状态」的既有语义（Global config 条目）不一致，修复应指向键的形态归属而非关闭传输。
- **迁移 legacy 值到手机桶、手机保留现状**：会偏袒覆盖方（手机）而剥夺被损害方（桌面）的既有定制；桌面是本缺陷的受害者，legacy 键归属受害者更符合「零迁移、不打断现状」原则。
- **同一设备按宽度在两桶间切换**：维持既有 runtime `tablLayout` 行为（宽=平板桶、窄=手机桶），无需存储层感知设备形态。
