import { test, expect } from "@playwright/test";
import { login, navigation, snapshot } from "./helpers";

test("原生工作区结构与设置偏好真实生效", async ({ page }) => {
    await page.setViewportSize({ width: 1200, height: 768 });
    let token = await login(page);
    const before = await snapshot(page, token);
    await expect(page.locator(".sidebar")).toHaveCSS("width", "220px");
    await expect(
        page
            .getByRole("group", { name: "日期导航", exact: true })
            .getByRole("button"),
    ).toHaveCount(14);
    await page.getByRole("button", { name: "收起侧栏", exact: true }).click();
    await expect(page.locator(".sidebar")).toHaveCSS("width", "72px");
    await page.getByRole("button", { name: "展开侧栏", exact: true }).click();
    const trigger = page.getByRole("button", { name: "设置", exact: true });
    await trigger.click();
    const settings = page.getByRole("dialog", { name: "设置", exact: true });
    await expect(settings).toBeVisible();
    await expect(settings.locator(".settings-navigation")).toHaveCSS(
        "width",
        "230px",
    );
    await settings
        .getByRole("button", { name: "微暖纸感", exact: true })
        .click();
    await expect(page.locator("html")).toHaveAttribute(
        "data-theme",
        "warmPaper",
    );
    await settings.getByRole("button", { name: "数据", exact: true }).click();
    await expect(
        settings.getByRole("button", { name: "生成并下载备份", exact: true }),
    ).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(settings).toHaveCount(0);
    await expect(trigger).toBeFocused();
    await expect(
        page.getByRole("heading", { name: "Day Todo", exact: true }),
    ).toBeVisible();
    await page.reload();
    token = await login(page);
    await expect(page.locator("html")).toHaveAttribute(
        "data-theme",
        "warmPaper",
    );
    await page.getByRole("button", { name: "设置", exact: true }).click();
    await page.getByRole("button", { name: "冷灰", exact: true }).click();
    await page.keyboard.press("Escape");
    expect((await snapshot(page, token)).sequence).toBe(before.sequence);
});

test("行内新增与非模态详情、日期和日历使用同一事实", async ({ page }) => {
    const token = await login(page);
    const before = await snapshot(page, token);
    const title = "原生工作区门禁：行内输入保持上下文";
    await page
        .getByRole("textbox", { name: "添加今日任务", exact: true })
        .fill(title);
    await page
        .getByRole("textbox", { name: "添加今日任务", exact: true })
        .press("Enter");
    await expect(
        page.getByRole("button", { name: title, exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: title, exact: true }).click();
    await expect(page.locator(".detail-rail")).toHaveCSS("width", "280px");
    await expect(
        page.getByRole("dialog", { name: "任务详情", exact: true }),
    ).toBeVisible();
    await expect(page.locator("dialog[open]")).toHaveCount(0);
    const after = await snapshot(page, token);
    expect(after.chains.length).toBe(before.chains.length + 1);
    await page.getByRole("button", { name: "后一天", exact: true }).click();
    await expect(
        page.getByRole("dialog", { name: "任务详情", exact: true }),
    ).toHaveCount(0);
    await navigation(page, "日历");
    await expect(
        page.getByRole("grid", { name: "月历", exact: true }),
    ).toBeVisible();
    await page
        .getByRole("button", { name: new RegExp("^" + before.today + " ") })
        .click();
    await page.getByRole("button", { name: "查看当天", exact: true }).click();
    await expect(
        page.getByRole("button", { name: title, exact: true }),
    ).toBeVisible();
});

test("回池不隐藏已完成子任务，手机关闭设置与右栏恢复焦点", async ({ page }) => {
    const token = await login(page);
    const title = "还原回归：保留已经完成的子任务";
    await page
        .getByRole("textbox", { name: "添加今日任务", exact: true })
        .fill(title);
    await page
        .getByRole("textbox", { name: "添加今日任务", exact: true })
        .press("Enter");
    await page.getByRole("button", { name: title, exact: true }).click();
    const detail = page.getByRole("dialog", { name: "任务详情", exact: true });
    await detail
        .getByLabel("子任务名称", { exact: true })
        .fill("已完成的小步骤");
    await detail
        .getByRole("button", { name: "添加子任务", exact: true })
        .click();
    await detail
        .getByRole("button", {
            name: "完成子任务：已完成的小步骤",
            exact: true,
        })
        .click();
    await detail
        .getByRole("button", { name: "回到任务池", exact: true })
        .click();
    await navigation(page, "已完成");
    await expect(
        page
            .locator(".completed-children")
            .filter({ hasText: "已完成的小步骤" }),
    ).toBeVisible();
    const state = await snapshot(page, token);
    expect(
        state.traces.some(
            (t) =>
                t.status === "returnedToPool" &&
                state.subtasks.some(
                    (s) => s.trace_id === t.id && s.status === "completed",
                ),
        ),
    ).toBe(true);
    await page.setViewportSize({ width: 390, height: 844 });
    await navigation(page, "设置");
    await page.keyboard.press("Escape");
    await expect(
        page.getByRole("button", { name: "打开导航", exact: true }),
    ).toBeFocused();
    await navigation(page, "Day Todo");
    await page.getByRole("button", { name: "展开右栏", exact: true }).click();
    await expect(
        page.getByRole("dialog", { name: "上下文右栏", exact: true }),
    ).toBeVisible();
    await expect(page.locator("#main-content")).toHaveAttribute("inert", "");
    await page.keyboard.press("Escape");
    await expect(
        page.getByRole("button", { name: "展开右栏", exact: true }),
    ).toBeFocused();
});

test("飞光与复盘离焦保存，表单内切换和取消不写入", async ({ page }) => {
    const token = await login(page);
    await navigation(page, "飞光");
    const original = "飞光原位交互门禁";
    const saved = original + "：离开编辑区域后保存";
    await page.getByLabel("记录内容", { exact: true }).fill(original);
    await page.getByLabel("记录内容", { exact: true }).press("Control+Enter");
    const note = page.locator(".idea-list > li").filter({ hasText: original });
    await note.locator(".idea-body").dblclick();
    let editing = page.getByRole("form", { name: "编辑记录", exact: true });
    await editing
        .getByRole("textbox", { name: "内容", exact: true })
        .fill(saved);
    await page.getByRole("heading", { name: "飞光", exact: true }).click();
    await expect(note.locator(".idea-body")).toHaveText(saved);
    const beforeCancel = await snapshot(page, token);
    await note.locator(".idea-body").dblclick();
    editing = page.getByRole("form", { name: "编辑记录", exact: true });
    await editing
        .getByRole("textbox", { name: "内容", exact: true })
        .fill("取消的修改不应形成事实");
    await editing.getByRole("button", { name: "取消", exact: true }).click();
    await expect(note.locator(".idea-body")).toHaveText(saved);
    expect((await snapshot(page, token)).sequence).toBe(beforeCancel.sequence);
    await navigation(page, "每日复盘");
    const beforeReview = await snapshot(page, token);
    await page
        .getByRole("textbox", { name: "今日总结", exact: true })
        .fill("复盘离焦保存门禁");
    await page
        .getByRole("textbox", { name: "未完成原因", exact: true })
        .focus();
    expect((await snapshot(page, token)).sequence).toBe(beforeReview.sequence);
    await page.getByRole("heading", { name: "Day Todo", exact: true }).click();
    await expect
        .poll(
            async () =>
                (await snapshot(page, token)).days.find(
                    (day) => day.date === beforeReview.today,
                )?.summary,
        )
        .toBe("复盘离焦保存门禁");
});

test("焦点仅属于当前可见且已认证的工作面", async ({ page }) => {
    const token = await login(page);
    const title = "菜单返回焦点门禁";
    const input = page.getByRole("textbox", {
        name: "添加今日任务",
        exact: true,
    });
    await input.fill(title);
    await input.press("Enter");
    const row = page.locator(".task-row").filter({ hasText: title });
    await row.locator("summary").click();
    await row.getByRole("button", { name: "查看详情", exact: true }).click();
    await page
        .getByRole("dialog", { name: "任务详情", exact: true })
        .getByRole("button", { name: "关闭", exact: true })
        .click();
    await expect(row.locator(".task-open")).toBeFocused();
    await page.getByRole("button", { name: "收起右栏", exact: true }).click();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: "展开右栏", exact: true }).click();
    const status = await page.evaluate(
        async (auth) =>
            (
                await fetch("/api/v1/auth/logout", {
                    method: "POST",
                    headers: { Authorization: `Bearer ${auth}` },
                    credentials: "omit",
                })
            ).status,
        token,
    );
    expect(status).toBe(200);
    const password = page.getByLabel("实例密码", { exact: true });
    await expect(password).toBeVisible();
    await expect(password).toBeFocused();
    await password.press("Shift+Tab");
    await expect(password).not.toBeFocused();
    await password.fill(process.env.NOONMARK_E2E_PASSWORD!);
    await page.getByRole("button", { name: "进入晷迹", exact: true }).click();
    await expect(
        page.getByRole("heading", { name: "Day Todo", exact: true }),
    ).toBeVisible();
    await expect(page.locator("#main-content")).not.toHaveAttribute("inert");
    await expect(page.locator(".detail-rail")).toHaveCount(0);
});
