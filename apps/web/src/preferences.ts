import { useCallback, useEffect, useRef, useState } from "react";

export interface Preferences {
    theme: "coolGray" | "warmPaper";
    swipeDirection: "book" | "reversed";
    shortcutsEnabled: boolean;
    poemEnabled: boolean;
    poem: string;
    stickyView: "stream" | "wall";
}

export const DEFAULT_POEM = `飞光飞光，劝尔一杯酒。
吾不识青天高，黄地厚。
唯见月寒日暖，来煎人寿。
食熊则肥，食蛙则瘦。
神君何在？太一安有？
天东有若木，下置衔烛龙。
吾将斩龙足，嚼龙肉，
使之朝不得回，夜不得伏。
自然老者不死，少者不哭。
何为服黄金，吞白玉？
谁似任公子，云中骑碧驴？
刘彻茂陵多滞骨，嬴政梓棺费鲍鱼。`;

export const DEFAULT_PREFERENCES: Preferences = {
    theme: "coolGray",
    swipeDirection: "book",
    shortcutsEnabled: true,
    poemEnabled: true,
    poem: DEFAULT_POEM,
    stickyView: "stream",
};

export type UpdatePreference = <Key extends keyof Preferences>(
    key: Key,
    value: Preferences[Key],
) => void;
type PreferenceState = {
    scope: string;
    preferences: Preferences;
    storageError: boolean;
};
const storageKey = (scope: string) => `noonmark.preferences:${scope}`;

function decode(raw: string | null): Preferences {
    if (raw === null) return { ...DEFAULT_PREFERENCES };
    const value: unknown = JSON.parse(raw);
    if (
        typeof value !== "object" ||
        value === null ||
        !("version" in value) ||
        value.version !== 1 ||
        !("preferences" in value)
    )
        throw new Error("PREFERENCES_INVALID");
    const preferences = value.preferences;
    if (
        typeof preferences !== "object" ||
        preferences === null ||
        !("theme" in preferences) ||
        !["coolGray", "warmPaper"].includes(String(preferences.theme)) ||
        !("swipeDirection" in preferences) ||
        !["book", "reversed"].includes(String(preferences.swipeDirection)) ||
        !("shortcutsEnabled" in preferences) ||
        typeof preferences.shortcutsEnabled !== "boolean" ||
        !("poemEnabled" in preferences) ||
        typeof preferences.poemEnabled !== "boolean" ||
        !("poem" in preferences) ||
        typeof preferences.poem !== "string" ||
        preferences.poem.length > 20000 ||
        !("stickyView" in preferences) ||
        !["stream", "wall"].includes(String(preferences.stickyView))
    )
        throw new Error("PREFERENCES_INVALID");
    return {
        theme: preferences.theme as Preferences["theme"],
        swipeDirection:
            preferences.swipeDirection as Preferences["swipeDirection"],
        shortcutsEnabled: preferences.shortcutsEnabled,
        poemEnabled: preferences.poemEnabled,
        poem: preferences.poem,
        stickyView: preferences.stickyView as Preferences["stickyView"],
    };
}

function readPreferences(scope: string): PreferenceState {
    try {
        return {
            scope,
            preferences: decode(
                scope ? localStorage.getItem(storageKey(scope)) : null,
            ),
            storageError: false,
        };
    } catch {
        return {
            scope,
            preferences: { ...DEFAULT_PREFERENCES },
            storageError: true,
        };
    }
}

export function usePreferences(scope: string) {
    const [state, setState] = useState<PreferenceState>(() =>
        readPreferences(scope),
    );
    const current = useRef(state);
    current.current = state;

    useEffect(() => {
        const next = readPreferences(scope);
        current.current = next;
        setState(next);
        const onStorage = (event: StorageEvent) => {
            if (event.key !== null && event.key !== storageKey(scope)) return;
            const updated = readPreferences(scope);
            current.current = updated;
            setState(updated);
        };
        window.addEventListener("storage", onStorage);
        return () => window.removeEventListener("storage", onStorage);
    }, [scope]);

    const updatePreference: UpdatePreference = useCallback(
        <Key extends keyof Preferences>(key: Key, value: Preferences[Key]) => {
            const previous =
                current.current.scope === scope
                    ? current.current
                    : readPreferences(scope);
            const preferences = { ...previous.preferences, [key]: value };
            let storageError = false;
            try {
                if (!scope) throw new Error("PREFERENCES_SCOPE_REQUIRED");
                localStorage.setItem(
                    storageKey(scope),
                    JSON.stringify({ version: 1, preferences }),
                );
            } catch {
                storageError = true;
            }
            const next = { scope, preferences, storageError };
            current.current = next;
            setState(next);
        },
        [scope],
    );

    return {
        preferences:
            state.scope === scope ? state.preferences : DEFAULT_PREFERENCES,
        storageError: state.scope === scope && state.storageError,
        updatePreference,
    };
}
