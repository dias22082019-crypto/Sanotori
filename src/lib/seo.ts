import { useEffect } from "react";

/** Уникальные title и description для каждой страницы (SEO публичных страниц санаториев) */
export function usePageMeta(title: string, description?: string) {
  useEffect(() => {
    document.title = title;
    if (description !== undefined) {
      let tag = document.querySelector<HTMLMetaElement>('meta[name="description"]');
      if (!tag) {
        tag = document.createElement("meta");
        tag.name = "description";
        document.head.appendChild(tag);
      }
      tag.content = description;
    }
  }, [title, description]);
}
