import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// One Markdown file per page under src/content/docs/<section>/. The folder is the
// sidebar section (see docsSections in src/data/site.config.ts); `order` sorts pages.
const docs = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    order: z.number().default(100),
    /** Which product the page is about; shown as a badge. */
    product: z.enum(['oss', 'pro', 'console']).optional(),
  }),
});

export const collections = { docs };
