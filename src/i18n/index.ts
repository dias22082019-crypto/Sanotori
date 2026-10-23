import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import ru from "./ru.json";
import kk from "./kk.json";

export const SUPPORTED_LANGUAGES = ["ru", "kk"] as const;
const STORAGE_KEY = "sanatorium-os.lang";

function initialLanguage(): "ru" | "kk" {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "ru" || saved === "kk") return saved;
  } catch {
    /* localStorage недоступен (приватный режим) */
  }
  return "ru";
}

void i18n.use(initReactI18next).init({
  resources: { ru: { translation: ru }, kk: { translation: kk } },
  lng: initialLanguage(),
  fallbackLng: "ru",
  interpolation: { escapeValue: false },
});

i18n.on("languageChanged", (lng) => {
  document.documentElement.lang = lng;
  try {
    localStorage.setItem(STORAGE_KEY, lng);
  } catch {
    /* ignore */
  }
});

/** Явный выбор пользователя запоминается; иначе применяется язык организации */
export function hasSavedLanguage(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) !== null;
  } catch {
    return false;
  }
}

export default i18n;
