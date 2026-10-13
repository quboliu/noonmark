import { test, expect } from "@playwright/test";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { login, navigation, snapshot } from "./helpers";

test("一年演示资料：真实长列表、跨季度历史与底部速记", async ({ page }) => {
    const reportRoot = join(process.env.NOONMARK_RUN_ROOT!, "reports");
    await mkdir(join(reportRoot, "screenshots"), { recursive: true });
    let pageErrors = 0;
    let failedAPI = 0;
    let revokedAuthorization = "";
    let expectedRevocations = 0;
    page.on("pageerror", () => {
        pageErrors++;
    });
    page.on("response", (response) => {
        if (
            new URL(response.url()).pathname.startsWith("/api/") &&
            response.status() >= 400
        ) {
            if (
                response.status() === 401 &&
                revokedAuthorization &&
                response.request().headers()["authorization"] ===
                    revokedAuthorization
            )
                expectedRevocations++;
            else failedAPI++;
        }
    });
    const token = await login(page);
    const before = await snapshot(page, token);
    expect(before.instance_id, "浏览器必须连接本轮已回读验收的演示实例").toBe(
        process.env.NOONMARK_DEMO_INSTANCE_ID,
    );
    const current = before.traces.filter(
        (trace) =>
            trace.date === before.today && trace.status !== "cancelledDraft",
    );
    const completed = before.traces.filter(
        (trace) => trace.status === "completed",
    );
    const totalReviews = before.days.filter((day) => day.summary.length > 0);
    const historicalReviews = before.days.filter(
        (day) => day.date < before.today && day.summary.length > 0,
    );
    const future = before.traces.filter(
        (trace) => trace.date > before.today && trace.status === "pending",
    );
    expect(current.length).toBeGreaterThanOrEqual(60);
    expect(completed.length).toBeGreaterThanOrEqual(365);
    expect(totalReviews.length).toBeGreaterThanOrEqual(365);
    expect(historicalReviews.length).toBeGreaterThanOrEqual(364);
    expect(future.length).toBeGreaterThanOrEqual(8);
    await expect(page.locator(".task-row")).toHaveCount(current.length);
    await page.screenshot({
        path: join(reportRoot, "screenshots", "demo-desktop.png"),
    });
    await page.evaluate(() =>
        document
            .querySelector(".main-content")!
            .scrollTo(0, document.querySelector(".main-content")!.scrollHeight),
    );
    expect(
        await page.evaluate(
            () =>
                document.querySelector(".main-content")!.scrollTop >
                innerHeight,
        ),
    ).toBe(true);
    await expect(page.locator(".sidebar")).toBeInViewport();
    await page.screenshot({
        path: join(reportRoot, "screenshots", "demo-desktop-bottom.png"),
    });
    await page.keyboard.press("Control+k");
    const dialog = page.getByRole("dialog", { name: "添加任务", exact: true });
    const title = dialog.getByLabel("任务名称", { exact: true });
    await expect(title).toBeEnabled();
    await expect(title).toBeFocused();
    await title.fill("一年演示验收：从长页面底部记录下一步");
    await dialog.getByLabel("安排日期", { exact: true }).fill(before.today);
    await dialog.getByRole("button", { name: "添加任务", exact: true }).click();
    await expect(dialog).toHaveCount(0);
    const after = await snapshot(page, token);
    expect(after.chains.length).toBe(before.chains.length + 1);
    expect(
        after.definitions.some(
            (definition) =>
                definition.title === "一年演示验收：从长页面底部记录下一步",
        ),
    ).toBe(true);
    await page
        .locator(".main-content")
        .evaluate((element) => element.scrollTo(0, 0));
    await page.setViewportSize({ width: 1200, height: 768 });
    await expect(page.locator(".sidebar")).toHaveCSS("width", "220px");
    await expect(
        page
            .getByRole("group", { name: "日期导航", exact: true })
            .getByRole("button"),
    ).toHaveCount(14);
    await page.locator(".task-row").first().locator("summary").click();
    await page
        .locator(".task-row")
        .first()
        .getByRole("button", { name: "查看详情", exact: true })
        .click();
    await expect(page.locator(".detail-rail")).toHaveCSS("width", "280px");
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-task-detail.png"),
    });
    await page
        .getByRole("dialog", { name: "任务详情", exact: true })
        .getByRole("button", { name: "关闭", exact: true })
        .click();
    await expect(page.locator(".task-open").first()).toBeFocused();
    await expect(
        page.getByRole("textbox", { name: "今日总结", exact: true }),
    ).toBeVisible();
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-day-review.png"),
    });
    await navigation(page, "设置");
    const settings = page.getByRole("dialog", { name: "设置", exact: true });
    await expect(settings).toHaveCSS("width", "860px");
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
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-settings-warm.png"),
    });
    await settings.getByRole("button", { name: "冷灰", exact: true }).click();
    await settings.screenshot({
        path: join(reportRoot, "screenshots", "native-settings-general.png"),
    });
    await settings.getByRole("button", { name: "数据", exact: true }).click();
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-settings-data.png"),
    });
    await page.keyboard.press("Escape");
    await navigation(page, "飞光");
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-flylight.png"),
    });
    await page.locator(".idea-body").first().dblclick();
    await expect(
        page
            .getByRole("form", { name: "编辑记录", exact: true })
            .getByRole("textbox", { name: "内容", exact: true }),
    ).toBeFocused();
    await expect(page.locator("dialog[open]")).toHaveCount(0);
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-flylight-inline.png"),
    });
    await page.keyboard.press("Escape");
    await navigation(page, "Sticky Note");
    await page.getByLabel("展示视图", { exact: true }).selectOption("wall");
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-sticky-wall.png"),
    });
    const sticky = page.locator(".idea-list > li").first();
    const sourceID = await sticky.getAttribute("data-idea-id");
    await sticky.getByRole("button", { name: "记录操作", exact: true }).click();
    await sticky
        .getByRole("button", { name: "在飞光中打开", exact: true })
        .click();
    await expect(page.locator(`[data-idea-id="${sourceID}"]`)).toBeFocused();
    await navigation(page, "日历");
    await page.screenshot({
        path: join(reportRoot, "screenshots", "native-calendar.png"),
    });
    await navigation(page, "Day Todo");
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(
        page.locator(".sidebar"),
        "移动侧栏收起后才采集页面证据",
    ).not.toBeInViewport();
    await expect(
        page.getByRole("heading", { name: "Day Todo", exact: true }),
    ).toBeVisible();
    await page.evaluate(() =>
        document.querySelector(".main-content")!.scrollTo(0, 0),
    );
    await page.screenshot({
        path: join(reportRoot, "screenshots", "demo-mobile.png"),
    });
    expect(
        await page.evaluate(
            () => document.documentElement.scrollWidth <= innerWidth,
        ),
        "长页面在移动尺寸不得横向溢出",
    ).toBe(true);
    await page.evaluate(() =>
        document
            .querySelector(".main-content")!
            .scrollTo(0, document.querySelector(".main-content")!.scrollHeight),
    );
    await page.screenshot({
        path: join(reportRoot, "screenshots", "demo-mobile-bottom.png"),
    });
    expect(
        await page.evaluate(() => {
            const ids = [...document.querySelectorAll("[id]")].map(
                (element) => element.id,
            );
            return ids.length === new Set(ids).size;
        }),
    ).toBe(true);
    await page.evaluate(() =>
        document.querySelector(".main-content")!.scrollTo(0, 0),
    );
    await navigation(page, "Sticky Note");
    await expect(page.locator(".idea-list > li")).toHaveCount(
        before.ideas.filter((idea) => idea.pinned_at && !idea.deleted_at)
            .length,
    );
    await navigation(page, "Day Todo");
    await page.getByRole("button", { name: "展开右栏", exact: true }).click();
    revokedAuthorization = `Bearer ${token}`;
    expect(
        await page.evaluate(
            async (authorization) =>
                (
                    await fetch("/api/v1/auth/logout", {
                        method: "POST",
                        headers: { Authorization: authorization },
                        credentials: "omit",
                    })
                ).status,
            revokedAuthorization,
        ),
    ).toBe(200);
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
    expect(expectedRevocations).toBeGreaterThan(0);
    expect(pageErrors).toBe(0);
    expect(failedAPI).toBe(0);
    await writeFile(
        join(reportRoot, "demo-browser-evidence.json"),
        JSON.stringify({
            verdict: "PASS",
            today_traces: current.length,
            review_days: totalReviews.length,
            historical_reviews: historicalReviews.length,
            completed_traces: completed.length,
            future_traces: future.length,
            page_errors: pageErrors,
            failed_api: failedAPI,
            long_scroll_command_committed: true,
            settings_panes: true,
            theme_switch: true,
            contextual_rail: true,
            flylight_inline_edit: true,
            sticky_source_navigation: true,
            calendar: true,
            checked_viewports: 3,
            revoked_session_releases_focus: true,
            expected_auth_rejections: expectedRevocations,
        }) + "\n",
    );
});
