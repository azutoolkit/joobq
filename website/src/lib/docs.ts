import { getCollection, type CollectionEntry } from 'astro:content';
import { site } from '../data/site.config';

export type DocEntry = CollectionEntry<'docs'>;

export interface SidebarSection {
  dir: string;
  label: string;
  blurb: string;
  pages: { slug: string; title: string; description: string; order: number }[];
}

/** The sidebar: one section per folder in src/content/docs, in docsSections order, pages by `order`. */
export async function getSidebar(): Promise<SidebarSection[]> {
  const entries = await getCollection('docs');
  return site.docsSections
    .map((section) => ({
      ...section,
      pages: entries
        .filter((entry) => entry.id.split('/')[0] === section.dir)
        .map((entry) => ({
          slug: entry.id,
          title: entry.data.title,
          description: entry.data.description,
          order: entry.data.order,
        }))
        .sort((a, b) => a.order - b.order || a.title.localeCompare(b.title)),
    }))
    .filter((section) => section.pages.length > 0);
}

/** Previous and next pages in sidebar order, for the footer of a docs page. */
export function neighbours(sidebar: SidebarSection[], slug: string) {
  const flat = sidebar.flatMap((section) => section.pages);
  const index = flat.findIndex((page) => page.slug === slug);
  return { prev: index > 0 ? flat[index - 1] : undefined, next: index >= 0 ? flat[index + 1] : undefined };
}
