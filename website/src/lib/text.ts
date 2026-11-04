/** Escapes HTML and turns `backtick` spans in data strings into <code> elements. */
export function inlineCode(text: string): string {
  const escaped = text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
  return escaped.replace(/`([^`]+)`/g, '<code>$1</code>');
}

/** Splits a heading into its text and a closing period, so the period can be drawn in the accent colour. */
export function withPeriod(title: string): { text: string; period: string } {
  const text = title.replace(/[.]$/, '');
  return { text, period: /[?!]$/.test(text) ? '' : '.' };
}
